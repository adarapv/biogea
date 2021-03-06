# Script for downloading google earthe at a high resolution (30 cm)
# and patch them together

library(rgdal);library(dismo)
library(stringi);library(tidyverse)
library(SDMTools);library(caret)
library(spatialEco);library(kernlab)
library(stringi)

# read in training polygons
map<-readOGR("/mnt/data1tb/Dropbox/curruspita/data/","CLM_Trainingpolygons")

# get REAL plot id
map@data %>%
    mutate(plotid1=paste(stri_split_fixed(plotid,"-",simplify=TRUE)[,1],
                         stri_split_fixed(plotid,"-",simplify=TRUE)[,2],
                         stri_split_fixed(plotid,"-",simplify=TRUE)[,3],sep="-")) ->map@data

#-----Step 1: get rasters from Google Earth

# list of unique plots
plot.l<-unique(map@data$plotid1)

# projection info needed 
# European Projection Info: http://spatialreference.org/ref/epsg/3035/ (see proj4)
laea<-CRS("+proj=laea +lat_0=52 +lon_0=10 +x_0=4321000 +y_0=3210000 +ellps=GRS80 +units=m +no_defs")
latlon<-CRS("+proj=longlat +datum=WGS84 +no_defs +ellps=WGS84 +towgs84=0,0,0")

# output directory
dir.create("/mnt/data1tb/Dropbox/curruspita/RGB_rasters")

for (i in 1:length(plot.l)){
    # print plot number
    cat(paste("plot ", i, " out of ",length(plot.l)," plots"),"\n")
    # subset specific plot
    tmp<-subset(map,plotid1==plot.l[i])
    # reproject to latlon (for safety!)
    tmp1<-spTransform(tmp,latlon)
    # and into Lambert Azimuth Equal area
    tmp2<-spTransform(tmp,laea)
    e<-extent(tmp1)
    gs<-gmap(e, type="satellite", scale=2, size=c(400, 400), zoom=16, rgb=T)
    # reproject map onto laea
    gs1<-projectRaster(gs,crs=laea,res=1)
    # crop on the basis of the extent of the plot
    gs2=crop(gs1,extent(tmp2))
    finalr<-mask(gs2,tmp2)
    # write out raster file onto directory
    filen<-paste("/mnt/data1tb/Dropbox/curruspita/RGB_rasters/","plot_",
                 stri_replace_all_fixed(plot.l[i],"-",""),".tif",sep="")
    writeRaster(finalr,filename=filen,overwrite=TRUE)
}

#-----Step 2: get statistics from plots (using training polygons)
file.l<-list.files("/mnt/data1tb/Dropbox/curruspita/RGB_rasters",full.names = TRUE)

statsresults<-NULL

for (i in 1:length(plot.l)){
    # print plot number
    cat(paste("plot ", i, " out of ",length(plot.l)," plots"),"\n")
    # subset specific plot
    tmp<-subset(map,plotid1==plot.l[i])
    # read in correct raster
    tmpr<-brick(file.l[grep(stri_replace_all_fixed(plot.l[i],"-",""),file.l)])
    # reproject plot into laea
    tmp1<-spTransform(tmp,laea)
    # go through each polygon and extract zonal statistics
    for (j  in 1:dim(tmp1@data)[1]){
        # print polygon number
        cat(paste("polygon ", j, " out of ",dim(tmp1@data)[1]," polygons"),"\n")
        # subset specific polygon
        tmp2<-tmp1[j,]
        # extract statistics for raster cells contained within polygon
        as.data.frame(raster::extract(tmpr,tmp2)[[1]]) %>%
            gather(band,value) %>%
            group_by(band) %>%
            summarise(mean=mean(value),min=min(value),max=max(value),
                      range=max(value)-min(value),mean_abs=mean(abs(value)),
                      stdev=sd(value),variance=var(value),sum=sum(value),
                      sum_abs=sum(abs(value)),median=median(value)) %>%
            mutate(area=area(tmp2)) %>%
            mutate(perimeter=polyPerimeter(tmp2)) %>%
            mutate(band=stri_split_fixed(band,".",simplify=TRUE)[,2]) %>%
            as.data.frame()->statsdf
        statsdf$landcover<-tmp2$landcover
        statsdf$plotid<-tmp2$plotid
        # reshape dataframe
        statsdf %>%
            gather(variable,value,-c(band,landcover,plotid)) %>%
            mutate(newcol=paste(variable,band,sep="_")) %>%
            dplyr::select(-c(band,variable))  %>%
            spread(newcol,value) ->statsdf1
        # bind results to final dataframe of results
            statsresults<-rbind(statsdf1,statsresults)
    }
}

write.csv(statsresults,file="/mnt/data1tb/Dropbox/curruspita/trainingdata/train.csv",row.names=FALSE)

#-----Step 3: perform supervised classification (with a number of algorithms)

# read in data, does a bit of filtering and exclude NAs
read.csv("/mnt/data1tb/Dropbox/curruspita/trainingdata/train.csv") %>%
    filter(landcover!="NA")  %>%
    filter(landcover!="nitrogen" & landcover!="ditches" & landcover!="agroforestry" & landcover!="stream") %>%
    mutate(landcover=as.factor(as.character(landcover))) %>% 
    dplyr::select(-c(plotid)) -> statsresults1

# caret settings: 5-fold cross validation repeated only once! 
ctrl = trainControl(method="repeatedcv", number=5,repeats=1, selectionFunction="best")

# partition the data (70% used for training, expressed in proportion)
in_train = createDataPartition(statsresults1$landcover, p=0.70, list=FALSE)

# Two algorithms: Random Forest and Support Vector Machines

# train RF model using and find best mtry parameter
mod1<-train(landcover~.,data=statsresults1, method="rf", 
metric="Accuracy", trControl=ctrl,subset=in_train)

# train SVM model using and find best C parameter
mod2<-train(landcover~.,data=statsresults1, method="svmRadial", 
metric="Accuracy", trControl=ctrl,subset=in_train)

# nice summary of results
results <- resamples(list(RF=mod1, SVM=mod2))

#-----Step 4: prepare new data for prediction: segmentation of new raster.
 
#Optmize segmentation through a grid search for the best threshold parameter.
# Quality assessed using intra-segment variance. More metrics need to
# be implemented (https://www.tandfonline.com/doi/abs/10.1080/01431160600617194)

# THIS IS AN EXAMPLE WITH ONE FILE: EVERYTHING SHOULD BE PUT IN A LOOP FROM THE START
# WITH MANY NEW PREDICTION AREAS

# read file into GRASS
system("r.in.gdal in=/mnt/data1tb/Dropbox/curruspita/newdata/exampletoclassify.tif out=example -o --o")

# uses i.segment.uspo for finding optimal segments
system("i.group group=example_bands input=example.1,example.2,example.3")

# ------- option 1: uses i.segment for finding optimal segments (personal implementation)

threshold.l<-seq(from=0.2,to=0.9,by=0.2)

res<-NULL

for (i in 1:length(threshold.l)){
    print(i)

# segmentation

i.seg<-paste("i.segment group=example_bands threshold=",threshold.l[i]," minsize=3",
" output=seg_",stri_replace_all_fixed(threshold.l[i],".","")," --o",sep="")
system(command=i.seg)

# write out file
out.gdal<-paste("r.out.gdal in=seg_",stri_replace_all_fixed(threshold.l[i],".",""),
" out=seg_",stri_replace_all_fixed(threshold.l[i],".",""),".tif"," --o",sep="")
system(command=out.gdal)

# extract cell counts for segments
r.stats<-paste("r.stats -An input=example.1,example.2,example.3",",seg_",
               stri_replace_all_fixed(threshold.l[i],".","")," > tmp",sep="")

system(command=r.stats)

# compute intra-segment variance weighted by area
tmp<-read.table("tmp")

tmp %>%
    # calculate polygon variance
    rename(band_1=V1,band_2=V2,band_3=V3,polygon_id=V4) %>%
    gather(band,value,-c(polygon_id)) %>%
    group_by(polygon_id) %>%
    summarise(poly.var=var(value)) %>%
    # insert area info
    inner_join(tmp %>%
    rename(band_1=V1,band_2=V2,band_3=V3,polygon_id=V4) %>%
    gather(band,value,-c(polygon_id)) %>%
    group_by(polygon_id) %>% summarise(area=(n())^2)) %>%
    mutate(tmp=poly.var*area) ->tmp1
   # calculate index
    tmpres<-data.frame(threshold=threshold.l[i],index=sum(tmp1$tmp)/sum(tmp1$area))
    res<-rbind(tmpres,res)

}

# option 2: segment optimization using the i.segment.upso module

system("g.region -d raster=example.1 save=myregion1")

system("i.segment.uspo group=example_bands threshold_start=0.02 threshold_stop=0.9 threshold_step=0.02 minsizes=3 processes=4 memory=4000 output=segparameters.csv regions=myregion1 --o")

# read in optimization output
read.csv("segparameters.csv") %>%
# select best parameter
filter(optimization_criteria==max(optimization_criteria)) ->optimal
# performs segmentation using best parameter
i.seg<-paste("i.segment group=example_bands threshold=",optimal$threshold," minsize=3",
" output=seg_",stri_replace_all_fixed(optimal$threshold,".","")," --o",sep="")
system(command=i.seg)

# convert raster into vector
r.to.vect<-paste("r.to.vect in=seg_",stri_replace_all_fixed(optimal$threshold,".","")," type=area out=seg_",stri_replace_all_fixed(optimal$threshold,".","")," --o",sep="")
system(command=r.to.vect)

# export vector as a shapefile
v.out.ogr<-paste("v.out.ogr in=seg_",stri_replace_all_fixed(optimal$threshold,".",""), " out=/mnt/data1tb/Dropbox/curruspita/newdata_forprediction/seg_",stri_replace_all_fixed(optimal$threshold,".","")," format=ESRI_Shapefile",sep="")
system(command=v.out.ogr)

# import shapefile (for example choose one

# optimal threshold (crappy)
newpoly<-readOGR("/mnt/data1tb/Dropbox/curruspita/newdata_forprediction/seg_022",layer="seg_022")

# threshold 0.8 fewer polygons, more realistic
#newpoly<-readOGR("/mnt/data1tb/Dropbox/curruspita/newdata_forprediction/seg_08",layer="seg_08")

# import original raster 
tmpr<-brick("/mnt/data1tb/Dropbox/curruspita/newdata_forprediction/exampletoclassify.tif")

newdata<-NULL

for (j  in 1:dim(newpoly@data)[1]){
        # print polygon number
        cat(paste("polygon ", j, " out of ",dim(newpoly@data)[1]," polygons"),"\n")
        # subset specific polygon
        tmp2<-newpoly[j,]
        # extract statistics for raster cells contained within polygon
        as.data.frame(raster::extract(tmpr,tmp2)[[1]]) %>%
            gather(band,value) %>%
            group_by(band) %>%
            summarise(mean=mean(value),min=min(value),max=max(value),
                      range=max(value)-min(value),mean_abs=mean(abs(value)),
                      stdev=sd(value),variance=var(value),sum=sum(value),
                      sum_abs=sum(abs(value)),median=median(value))  %>%
            mutate(area=area(tmp2)) %>%
            mutate(perimeter=polyPerimeter(tmp2)) %>%
            mutate(band=stri_split_fixed(band,".",simplify=TRUE)[,2]) %>%
            as.data.frame()->statsdf
          statsdf$rown<-j
        # reshape dataframe
        statsdf %>%
            gather(variable,value,-c(band,rown)) %>%
            mutate(newcol=paste(variable,band,sep="_")) %>%
            dplyr::select(-c(band,variable))  %>%
            spread(newcol,value) ->statsdf1
        # bind results to final dataframe of results
            newdata<-rbind(statsdf1,newdata)

}



write.csv(newdata,file="/mnt/data1tb/Dropbox/curruspita/newdata_forprediction/newdatstats_022.csv",row.names=FALSE)

#-----Step 5: classify new areas using models developed
# choose one either 0.22 or 0.8 (latter better)

# re-order row number in same order as shapefile

#read.csv("/mnt/data1tb/Dropbox/curruspita/newdata_forprediction/newdatstats_022.csv") %>%
#arrange(rown) ->newdata1

read.csv("/mnt/data1tb/Dropbox/curruspita/newdata_forprediction/newdatstats_08.csv") %>%
arrange(rown) ->newdata1


# best model Random Forest: the function uses the optimized  model
newpoly@data$landcover<-predict(mod1,newdata1,type="raw")

writeOGR(newpoly,dsn="/mnt/data1tb/Dropbox/curruspita/results",layer="classifiedpoly1",
driver="ESRI Shapefile")



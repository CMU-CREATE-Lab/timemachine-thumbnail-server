Time Machine Thumbnail Service API
==================================

The thumbnail service renders arbitrary image/video/gif thumbnails from Time Machines accessible over HTTP/HTTPS.  While the thumbnail service lives on timemachine-api.cmucreatelab.org, it can render thumbnails for Time Machines served anywhere over HTTP or HTTPS.

Examples
--------

JPEG thumbnail from Earth Timelapse, from the Brazilian State of Rondonia in 2012:
<img src="http://timemachine-api.cmucreatelab.org/thumbnail?root=http://earthengine.google.org/timelapse/data/20130507&boundsNWSE=-8.02999,-65.51147,-13.56390,-59.90845&width=200&frameTime=2.8">
http://timemachine-api.cmucreatelab.org/thumbnail?root=http://earthengine.google.org/timelapse/data/20130507&boundsNWSE=-8.02999,-65.51147,-13.56390,-59.90845&width=200&frameTime=2.8

GIF thumbnail from a Shenango Coke Works smoke emission in 2014:
<img src="http://timemachine-api.cmucreatelab.org/thumbnail?root=http://explorables.cmucreatelab.org/environmental-timemachines/shenango-20141005-20141006-tm/&boundsLTRB=2084.88990915391,1273.0414920286516,3791.489909153904,2519.6414920286475&width=320&height=240&frameTime=877.8333333333334&nframes=10&format=gif&tileFormat=mp4&label=2014-10-06%2009:30:31">
http://timemachine-api.cmucreatelab.org/thumbnail?root=http://explorables.cmucreatelab.org/environmental-timemachines/shenango-20141005-20141006-tm/&boundsLTRB=2084.88990915391,1273.0414920286516,3791.489909153904,2519.6414920286475&width=320&height=240&frameTime=877.8333333333334&nframes=10&format=gif&tileFormat=mp4&label=2014-10-06%2009:30:31

API
---

http://timemachine-api.cmucreatelab.org/thumbnail?_[flags]_

`root=`_rootUrl_

Root URL for time machine JSON and tiles.  The file `tm.json` should be found at _rootUrl_`/tm.json`.  rootUrl should not contain a trailing ‘/’.

`boundsLTRB=`_left,top,right,bottom_

Source bounds for thumbnail, in the pixel coordinates of the time machine.  Must specify either this or ```boundsNWSE```.

```boundsNWSE=```_north,west,south,east_
Source bounds for the thumbnail, in lat/lon coordinates.  Only allowed if time machine includes projection data to allow conversion from lat/lon to pixel coordinates.  Must specify either this or ```boundsLTRB```.  Lat and lon are standard decimal representations, with positive lat representing north, and positive lon representing east.

```width=```_width_
Output width of thumbnail, in pixels.  

Output size in pixels can be specified by either or both of ```width``` or ```height```;  the unspecified dimension will automatically be calculated based on the aspect ratio from the source rectangle (as specified by ```boundsLTRB``` or ```boundsNWSE```).  If both ```width``` and ```height``` are be provided, the source rectangle will be tweaked if needed to produce output of exactly the specified aspect ratio.

```height=```_height_
Output height of thumbnail, in pixels.  Must specify one or both of ```width``` and ```height```; see below.  (Due to a limitation of ffmpeg, height of 1 pixel appears to not be supported.  Use height of 2 pixels or more until we work around this.)

```nframes=```_nframes_
Optional number of frames to output.  Default is 1, to output a single frame.

```format=```_suffix_
Optional output format (```jpg```, ```png```, ```gif```, ```mp4```, ```rgb24```).  If omitted, defaults to jpg.  ```mp4```, ```gif```, and ```rgb24``` allow multiple-frame animations.  ```jpg``` and ```png``` are single-frame formats, which require nframes be omitted or set to 1.  ```rgb24``` packs output as 3 bytes per pixel (r, g, b), in row-major order.  

```frameTime=```_timeInSeconds_
Optional playback time for frame, in seconds.  If omitted, defaults to 0 (first frame).

```frameTimeEnd=```_timeInSeconds_
Optional playback time for last frame, in seconds.  Used when outputting image sequences.  If omitted, frameTimeEnd is calculated from nframes based on frame rate of the original video source.  2014-March-07: NOT YET IMPLEMENTED

**Options you shouldn’t need to use:**

```debug```
Optional: show debugging output from service rather than outputting an image.

```recompute```
Optional: force recomputation of image, even if present in cache.  _Please only use this for debugging or benchmarking, never in production._

```test```
Optional:  perform regression test on service.  _Warning:_ the thumbnails on the test page set ```recompute``` to ensure bugs aren't masked by the cache.  Do _not_ use these thumbnails as example URLs unless you're very careful to remove the ```recompute``` flag!

```tileFormat=```_format_
Optional format to select from Time Machine tile source.  Defaults to ```webm```, to work around an ffmpeg seek bug.  If your tile source only has ```mp4``` files, you can try setting this to ```mp4```.


Installation
------------

If you want to install your own copy of the thumbnail server:

- Edit cache_dir and ffmpeg_path in thumbnail-server.rb
- Set up as a cgi script for your webserver

If you're developing on a Mac, you can run this under apache on your mac; look at apache-config-examples/osx-rsargent.conf and follow the comments at the top of that file to customize and install.

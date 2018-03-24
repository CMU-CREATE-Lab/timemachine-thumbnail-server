#!/usr/local/bin/ruby

# Next steps:
# Whitelist for time machine host to mitigate potential ffmpeg security issues
# Implement BoundsLTRB
# Figure out mp4 seek problem with ffmpeg

# Full world: http://localhost/cgi-bin/thumbnail?root=http%3A%2F%2Fearthengine.google.org%2Ftimelapse%2Fdata%2F20130507&boundsNWSE=85.051128,-180,-85.051128,180&height=100&frameTime=0

# Northern hemisphere: http://localhost/cgi-bin/thumbnail?root=http%3A%2F%2Fearthengine.google.org%2Ftimelapse%2Fdata%2F20130507&boundsNWSE=85.051128,-180,0,180&height=100&frameTime=0

# Southern hemisphere: http://localhost/cgi-bin/thumbnail?root=http%3A%2F%2Fearthengine.google.org%2Ftimelapse%2Fdata%2F20130507&boundsNWSE=0,-180,-85.051128,180&height=100&frameTime=0

# Rondonia http://localhost/cgi-bin/thumbnail?root=http%3A%2F%2Fearthengine.google.org%2Ftimelapse%2Fdata%2F20130507&boundsNWSE=-8.02999,-65.51147,-13.56390,-59.90845&width=200&frameTime=2.8

# Rondonia samples over time: http://localhost/cgi-bin/thumbnail?root=http%3A%2F%2Fearthengine.google.org%2Ftimelapse%2Fdata%2F20130507&boundsNWSE=-10,-63,-11,-62&width=1&height=2&nframes=29&format=rgb24

# Cache design:
#   Hash URL using


require 'json'
require 'cgi'
require 'open-uri'
require 'digest'
require 'fileutils'
require 'bigdecimal'
require 'bigdecimal/util'
require 'selenium-webdriver'

load File.dirname(File.realpath(__FILE__)) + '/mercator.rb'
load File.dirname(File.realpath(__FILE__)) + '/point.rb'
load File.dirname(File.realpath(__FILE__)) + '/bounds.rb'
load File.dirname(File.realpath(__FILE__)) + '/FlockSemaphore.rb'

cache_dir = File.dirname(File.realpath(__FILE__)) + '/cache'

filter_dir = File.dirname(File.realpath(__FILE__)) + '/filters'

ffmpeg_path = '/usr/local/bin/ffmpeg'
num_threads = 8
from_screenshot = false

cgi = CGI.new
cgi.params = CGI::parse(ENV.to_hash['REQUEST_URI'])
cgi.params['root'] = cgi.params.delete('/thumbnail?root')

debug = []

def parse_bounds(cgi, key)
  if not cgi.params.has_key?(key)
    return false
  end
  bounds = cgi.params[key][-1].gsub("02C", ",").split(',').map(&:to_f)
  bounds.size == 4 or raise "#{key} was specified without the required 4 coords separated by commas"
  bounds
end



begin
  debug << "<html><body>"
  debug << "<pre>"
  debug << JSON.pretty_generate(ENV.to_hash)
  debug << "</pre><hr><pre>"
  debug << JSON.pretty_generate(cgi.params)
  debug << "</pre>"
  debug << "<hr>"

  if cgi.params.has_key? 'test'
    test_html = File.open(File.dirname(File.realpath(__FILE__)) + '/test.html').read
    cgi.out('Access-Control-Allow-Origin' => '*') {test_html}
    exit
  end

  root = cgi.params['root'][0] or raise "Missing 'root' param"
  root = root.sub(/\/$/, '')
  debug << "root: #{root}<br>"

  format = cgi.params['format'][0] || 'jpg'

  tile_format = cgi.params['tileFormat'][0] || 'webm'

  nframes = cgi.params['nframes'][0] || 1
  nframes = nframes.to_i

  recompute = cgi.params.has_key? 'recompute'

  if ENV['QUERY_STRING']
    # Running in CGI mode;  enable cache
    cache_path = ENV['QUERY_STRING'].split("cachepath=")[1]
    cache_file = "#{cache_dir}#{cache_path}"
    FileUtils.mkdir_p(File.dirname(cache_file))
  else
    # Running from commandline;  don't cache
    cache_file = nil
  end

  $vlog_logfile = File.open(File.dirname(File.dirname(File.realpath(__FILE__))) + '/log.txt' , 'a')
  $id = "%06d" % rand(1000000) 
  $stats = {}
  $begin_time = Time.now 
  
  def vlog(shardno, msg)
    $vlog_logfile.write("#{Time.now.strftime('%Y-%m-%d %H:%M:%S.%3N')} THUMB #{Process.pid}:#{$id}:#{shardno} #{msg}\n")
    $vlog_logfile.flush
  end

  # Loop
  #   If thumbnail is in cache use it, done
  #   Create and attempt to (non-blocking) acquire lock on <cachepath>.computing
  #   Acquired? break from loop

  from_screenshot = cgi.params.has_key?('fromScreenshot')
  image_data = nil
  compute_path = cache_file + '.compute'
  compute_file = nil

  while true
    if File.exists?(cache_file) and not recompute
      vlog(0, "Found in cache.")
      debug << "Found in cache."
      image_data = open(cache_file, 'rb') {|i| i.read}
      break
    end

    # If file isn't in cache and we've already locked the compute_file, exit loop and compute
    if compute_file
      break
    end
    
    compute_file = File.open(compute_path, 'w')
    if not compute_file.flock(File::LOCK_NB | File::LOCK_EX)
      vlog(0, "Cannot lock compute lockfile; waiting for another process to finish computing")
      sleep(1)
      compute_file.close
      compute_file = nil
    end
  end

  if image_data and compute_file
    compute_file.close
    compute_file = nil
    FileUtils.rm_f(compute_path)
  end

  if not image_data
    vlog(0, "Not found in cache; computing")
    $request_url = ENV['REQUEST_SCHEME'] + '://' + ENV['HTTP_HOST'] + ENV['REQUEST_URI']
    vlog(0, "STARTTHUMBNAIL #{$request_url}")


    boundsNWSE = parse_bounds(cgi, 'boundsNWSE')
    boundsLTRB = parse_bounds(cgi, 'boundsLTRB')
    if !boundsNWSE and !boundsLTRB
      if from_screenshot
        boundsFromSharelink = true
      else
        raise "Must specify boundsNWSE or boundsLTRB, unless fromScreenshot"
      end
    else
      if boundsNWSE and boundsLTRB
        raise "Both boundsNWSE and boundsLTRB were specified;  please specify only one"
      end
    end
    
    if from_screenshot
      semaphore = FlockSemaphore.new('/t/thumbnails.cmucreatelab.org/locks')
      while true
        lock = semaphore.captureNonblock
        if lock
          vlog(0, "Captured resource lock #{lock}")
          break
        else
          vlog(0, "Waiting to capture resource lock in /t/thumbnails.cmucreatelab.org/locks")
        end
        sleep(1)
      end
      
      Selenium::WebDriver.logger.output = STDERR
      #Selenium::WebDriver.logger.level = :info

      def queue_pop_nonblock(queue)
        begin
          return queue.pop(non_block=true)
        rescue ThreadError
          return nil
        end
      end

      extra_css = "";

      make_chrome = ->(shardno, url, output_width, output_height, screenshot_bounds) {
        before = Time.now
        options = Selenium::WebDriver::Chrome::Options.new
        options.add_argument('--headless')
        options.add_argument('--hide-scrollbars')
        driver = Selenium::WebDriver.for :chrome, options: options
        vlog(shardno, "make_chrome loading #{url}")

        # Resize the window to desired width/height.
        driver.manage.window.resize_to(output_width, output_height)
        # Navigate to the page; will block until the load is complete.
        # Note: Any ajax requests or large data files may not be loaded yet.
        #       We take care of that further down when taking the actual screenshots.
        driver.navigate.to url
        vlog(shardno, "make_chrome: #{driver.execute_script('{canvasLayer.setAnimate(false); return timelapse.frameno}')} frames before setAnimate(false)");

        # Just in case
        sleep(1)

        driver.execute_script("timelapse.setNewView(#{screenshot_bounds.to_json}, true);" + extra_css)
        ## Just in case
        #sleep(1)

        vlog(shardno, "make_chrome took #{((Time.now - before) * 1000).round} ms")
        return driver
      }

      # Convert URL encoded characters back to their original values
      root.gsub!("023", "#")
      root.gsub!("026", "&")
      root.gsub!("03D", "=")
      root.gsub!("02C", ",")

      root += root.include?("#") ? "&" : "#"

      screenshot_from_video = root.include?("blsat")

      root_url_params = CGI::parse(root)

      if cgi.params.has_key?('minimalUI')
        root += "minimalUI=true"
      elsif cgi.params.has_key?('timestampOnlyUI')
        root += "timestampOnlyUI=true"
        extra_css = "$('.captureTime.minimalUIMode').css('transform', 'translate(-50%,0)').css('left', '50%');"
        #extra_css = "$('.captureTime.minimalUIMode').css('left', '50%');"
      else
        root += "disableUI=true"
      end

      output_width = cgi.params['width'][0].to_i || 128
      output_height = cgi.params['height'][0].to_i || 74

      #
      # Parse bounds
      #

      screenshot_bounds = {}
      if boundsFromSharelink
        view = root_url_params['v'][0].split(',')
        if view[-1] == 'pts'
          screenshot_bounds = {'bbox' => {'xmin' => view[0].to_f, 'ymin' => view[1].to_f}, 'xmax' => view[2].to_f, 'ymax' => view[3].to_f}
        elsif view[-1] == 'latLng'
          screenshot_bounds = {'center' => {'lat' => view[0].to_f, 'lng' => view[1].to_f}, 'zoom' => view[2].to_f}
        else
          vlog(0, 'boundsFromSharelink parsing failed')
          raise 'boundsFromSharelink parsing failed'
        end
      elsif boundsNWSE
        screenshot_bounds['bbox'] = {}
        screenshot_bounds['bbox']['ne'] = {'lat' => boundsNWSE[0], 'lng' => boundsNWSE[1]}
        screenshot_bounds['bbox']['sw'] = {'lat' => boundsNWSE[2], 'lng' => boundsNWSE[3]}
      else
        screenshot_bounds['bbox'] = {}
        screenshot_bounds['bbox']['xmin'] = boundsLTRB[0]
        screenshot_bounds['bbox']['ymin'] = boundsLTRB[1]
        screenshot_bounds['bbox']['xmax'] = boundsLTRB[2]
        screenshot_bounds['bbox']['ymax'] = boundsLTRB[3]
      end
      vlog(0, "screenshot_bounds #{screenshot_bounds}")

      driver = make_chrome.call(0, root, output_width, output_height, screenshot_bounds)

      # 0 - 100.  If ps is missing or set to zero, override to 50
      screenshot_playback_speed = root_url_params.has_key?('ps') ? root_url_params['ps'][0].to_f : 50.0
      if screenshot_playback_speed < 1e-10
        screenshot_playback_speed = 50.0
      end
                                          
      # YYYYMMDD
      screenshot_begin_time_as_date = root_url_params.has_key?('bt') ? root_url_params['bt'][0] : 0.0
      # YYYYMMDD
      screenshot_end_time_as_date = root_url_params.has_key?('et') ? root_url_params['et'][0] : driver.execute_script("return timelapse.getDuration();").to_d.truncate(1).to_f

      debug << "screenshot_playback_speed: #{screenshot_playback_speed}<br>"
      debug << "screenshot_begin_time_as_date #{screenshot_begin_time_as_date}<br>"
      debug << "screenshot_end_time_as_date #{screenshot_end_time_as_date}<br>"

      screenshot_begin_time_as_render_time = driver.execute_script("return timelapse.playbackTimeFromShareDate('#{screenshot_begin_time_as_date}')").to_f
      screenshot_end_time_as_render_time = driver.execute_script("return timelapse.playbackTimeFromShareDate('#{screenshot_end_time_as_date}')").to_f

      debug << "screenshot_begin_time_as_render_time: #{screenshot_begin_time_as_render_time}<br>"
      debug << "screenshot_end_time_as_render_time: #{screenshot_end_time_as_render_time}<br>"

      dataset_num_frames = driver.execute_script("return timelapse.getNumFrames();").to_f
      dataset_fps = driver.execute_script("return timelapse.getFps();").to_f
      viewer_max_playback_rate = driver.execute_script("return timelapse.getMaxPlaybackRate();").to_f

      debug << "viewer_max_playback_rate: #{viewer_max_playback_rate}<br>"
    else

      #
      # Fetch tm.json
      #

      tm_url = "#{root}/tm.json"
      debug << "tm_url: #{tm_url}<br>"
      tm = open(tm_url) {|i| JSON.parse(i.read)}
      debug << JSON.dump(tm)
      debug << "<hr>"

      # Use first dataset if there are multiple
      dataset = tm['datasets'][0]

      #
      # Fetch r.json
      #

      r_url = "#{root}/#{dataset['id']}/r.json"
      debug << "r_url: #{r_url}<br>"
      r = open(r_url) {|i| JSON.parse(i.read)}
      debug << JSON.dump(r)
      debug << "<br>"

      dataset_num_frames = r['frames'].to_f
      dataset_fps = r['fps'].to_f
      nframes = [nframes, dataset_num_frames].min

      #
      # Parse bounds
      #

      timemachine_width = r['width']
      timemachine_height = r['height']
      debug << "timemachine dims: #{timemachine_width} x #{timemachine_height}<br>"

      if boundsNWSE
        projection_bounds = tm['projection-bounds'] or raise "boundsNWSE were specified, but #{tm_url} is missing projection-bounds"

        projection = MercatorProjection.new(projection_bounds, timemachine_width, timemachine_height)
        debug << "projection-bounds: #{JSON.dump(projection_bounds)}<br>"

        debug << "boundsNWSE: #{boundsNWSE.join(', ')}<br>"
        ne = projection.latlngToPoint({'lat' => boundsNWSE[0], 'lng' => boundsNWSE[1]})
        sw = projection.latlngToPoint({'lat' => boundsNWSE[2], 'lng' => boundsNWSE[3]})

        bounds = Bounds.new(Point.new(ne['x'], ne['y']), Point.new(sw['x'], sw['y']))

      else
        bounds = Bounds.new(Point.new(boundsLTRB[0], boundsLTRB[1]),
                            Point.new(boundsLTRB[2], boundsLTRB[3]))
      end

      input_aspect_ratio = bounds.size.x.to_f / bounds.size.y
      debug << "bounds: #{bounds}<br>"
    end

    #
    # Requested output size
    #

    output_width = cgi.params['width'][0]
    output_width &&= output_width.to_i
    output_height = cgi.params['height'][0]
    output_height &&= output_height.to_i

    ignore_aspect_ratio = cgi.params.has_key? 'ignoreAspectRatio'

    if !output_width && !output_height
      raise "Must specify at least one of 'width' and 'height'"
    elsif output_width && output_height
      if  !ignore_aspect_ratio
        #
        # output aspect ratio was specified.  Tweak input bounds to match output aspect ratio, by selecting
        # new bounds with the same center and area as original.
        #
        output_aspect_ratio = output_width.to_f / output_height
        if not from_screenshot
          aspect_factor = Math.sqrt(output_aspect_ratio / input_aspect_ratio)
          bounds = Bounds.with_center(bounds.center,
                                    Point.new(bounds.size.x * aspect_factor, bounds.size.y / aspect_factor))
          debug << "Modified bounds to #{bounds} to preserve aspect ratio<br>"
        end
      else
        debug << "width, height, ignoreAspectRatio all specified;  using width and height as specified<br>"
      end
    elsif output_width
      output_height = (output_width / input_aspect_ratio).round
    else
      output_width = (output_height * input_aspect_ratio).round
    end

    # Min width/height allowed by ffmpeg is 46x46
    output_width = [output_width, 46].max
    output_height = [output_height, 46].max

    # Ensure that the width and height are multiples of 2 for ffmpeg
    output_width = ((output_width - 1) / 2 + 1) * 2
    output_height = ((output_height - 1) / 2 + 1) * 2

    debug << "output size: #{output_width}px x #{output_height}px<br>"

    frame_time = cgi.params['frameTime'][0].to_f
    start_frame = cgi.params['startFrame'][0]

    # If both frameTime and startFrame are passed in, startFrame takes precedence.
    if start_frame
      dataset_frame_length = (dataset_num_frames / dataset_fps) / dataset_num_frames
      start_frame = start_frame.to_i
      frame_time = start_frame * dataset_frame_length
    else
      dataset_frame_length = (dataset_num_frames / dataset_fps) / dataset_num_frames
      start_frame = (frame_time / dataset_frame_length).floor
    end

    max_time = (dataset_num_frames - 0.25).to_f / dataset_fps
    time = [0, [max_time, frame_time.to_f].min].max

    debug << "Time to seek to: #{time}<br>"

    leader_seconds = 0
    if r and r.has_key?('leader')
      # FIXME: fractional leaders...
      leader_seconds = r['leader'].floor / dataset_fps
      debug << "Adding #{leader_seconds} seconds of leader<br>"
      time += leader_seconds
    end

    if cache_file
      tmpfile = "#{cache_file}.tmp-#{Process.pid}.#{format}"
    else
      tmpfile = "/tmp/thumbnail-server-#{Process.pid}.#{format}"
    end

    tmpfile_root_path = File.dirname(tmpfile)

    is_image = true
    is_video = (format == 'mp4' or format == 'webm') ? true : false

    raw_formats = ['rgb24', 'gray8']

    if raw_formats.include? format or format == 'gif' or is_video
      is_image = false
    end


    #
    # Fps for video output
    #
    #
    video_output_fps = ""
    desired_fps = dataset_fps
    if cgi.params.has_key? 'fps'
      desired_fps = cgi.params['fps'][0].to_f
      if is_video
        raise "Output fps is required and must be greater than 0" unless desired_fps
        video_output_fps = "-r #{desired_fps}"
      end
    end


    #
    # Take a screenshot of a page passed in as the root
    #
    #
    if from_screenshot
      begin
        start_frame ||= 0
        total_chrome_frames = 0

        tmpfile_screenshot_input_path = tmpfile_root_path + "/#{(Time.now.to_f*1000).to_i}"
        FileUtils.mkdir_p(tmpfile_screenshot_input_path) unless File.exists?(tmpfile_screenshot_input_path)

        screenshot_playback_rate = (100.0 / screenshot_playback_speed)
        video_duration_in_secs = (screenshot_end_time_as_render_time - screenshot_begin_time_as_render_time) /  (viewer_max_playback_rate / screenshot_playback_rate)
        nframes = is_image ? 1 : (video_duration_in_secs * desired_fps).ceil

        vlog(0, "Need to compute #{nframes} frames")
        frame_queue = Queue.new
        (0 ... nframes).each { |i| frame_queue << i }

        # Capture frames from ... to-1
        new_capture_frames_thread = ->(shardno, driver) {
          return Thread.new {
            vlog(shardno, "Shard starting");

            while true do
              frame = queue_pop_nonblock(frame_queue)
              if frame == nil
                break
              end
              if not driver then
                frame_queue << frame
                driver = make_chrome.call(shardno, root, output_width, output_height, screenshot_bounds)
                frame = queue_pop_nonblock(frame_queue)
                if frame == nil
                  break
                end
              end
              seek_time = (frame.to_f / [1.0, (nframes.to_f - 1.0)].max) * (screenshot_end_time_as_render_time - screenshot_begin_time_as_render_time) + screenshot_begin_time_as_render_time
              vlog(shardno, "frame #{frame} seeking to: #{seek_time}")

              before = Time.now
              driver.execute_script("timelapse.seek(#{seek_time});")

              while true do
                # Wait at most 30 seconds until we assume things are drawn
                if (Time.now - before) > 30
                  vlog(shardno, "giving up on frame #{frame} after #{((Time.now - before) * 1000).round}ms; stopping driver")
                  frame_queue << frame
                  total_chrome_frames += driver.execute_script("return timelapse.frameno")
                  driver.quit
                  driver = nil
                  break
                end
                complete = driver.execute_script(
                  "{" +
                  extra_css +
                  "timelapse.setNewView(#{screenshot_bounds.to_json}, true);" +
                  "timelapse.seek(#{seek_time});" +
                  "canvasLayer.update_();" +
                  "return timelapse.lastFrameCompletelyDrawn && timelapse.frameno;" +
                  "}"
                )
                if complete
                  driver.save_screenshot("#{tmpfile_screenshot_input_path}/#{'%04d' % frame}.png")
                  vlog(shardno, "frame #{frame} took #{((Time.now - before) * 1000).round} ms (chrome frame #{complete})");
                  break
                else
                  vlog(shardno, "frame #{frame} called update but not ready yet");
                  sleep(0.05);
                end
              end
            end
            vlog(shardno, "Shard finished");
            if driver then
              total_chrome_frames += driver.execute_script("return timelapse.frameno")
              driver.quit
            end
          }
        }

        nshards = (nframes / 5).floor
        if nshards < 1
          nshards = 1
        end
        if nshards > 6
          nshards = 6
        end

        $stats['nshards'] = nshards

        shard_threads = []

        (0 ... nshards).each do |shardno|
          if shardno == 0
            thread_driver = driver
          else
            thread_driver = nil
          end
          shard_threads << new_capture_frames_thread.call(shardno, thread_driver)
        end

        shard_threads.each { |shard_thread| shard_thread.join }

        vlog(0, "Chrome rendered a total of #{total_chrome_frames} frames, for #{nframes} frames needed (#{"%.1f" % (nframes * 100.0 / total_chrome_frames)}%)")
        $stats['chromeRenderTimeSecs'] = Time.now - $begin_time
        $stats['videoFrameCount'] = nframes
        $stats['frameEfficiency'] = nframes.to_f / total_chrome_frames
      rescue Selenium::WebDriver::Error::TimeOutError
        raise "Error taking screenshot. Data failed to load."
      end
    else
      #
      # Search for tile from the tile tree
      #

      tile_url = crop = nil

      output_subsample = [bounds.size.x / output_width, bounds.size.y / output_height].max

      debug << "output_subsample: #{output_subsample}<br>"

      # ffmpeg refuses to subsample more than this?
      maximum_ffmpeg_subsample = 64

      tile_spacing = Point.new(r['tile_width'], r['tile_height'])
      video_size = Point.new(r['video_width'], r['video_height'])

      # Start from highest level (most detailed) and "zoom out" until a tile is found
      # to completely cover the requested area
      r['nlevels'].times do |i|
        subsample = 1 << i
        tile_coord = (bounds.min / subsample / tile_spacing).floor
        level = r['nlevels'] - i - 1

        # Reject level if it would require subsampling more than ffmpeg allows
        required_subsample = output_subsample / subsample
        if required_subsample > maximum_ffmpeg_subsample
          debug << "level #{level} would have required tile to be subsampled by #{required_subsample}, rejecting<br>"
          next
        end

        tile_bounds = Bounds.new(tile_coord * tile_spacing * subsample,
                                 (tile_coord * tile_spacing + video_size) * subsample)

        tile_url = "#{root}/#{dataset['id']}/#{level}/#{tile_coord.y}/#{tile_coord.x}.#{tile_format}"
        debug << "subsample #{subsample}, tile #{tile_bounds} #{tile_url} contains #{bounds}? #{tile_bounds.contains bounds}<br>"
        if tile_bounds.contains bounds or level == 0
          debug << "Best tile: #{tile_coord}, level: #{level} (subsample: #{subsample})<br>"

          tile_coord.x = [tile_coord.x, 0].max
          tile_coord.y = [tile_coord.y, 0].max
          tile_coord.x = [tile_coord.x, r['level_info'][level]['cols'] - 1].min
          tile_coord.y = [tile_coord.y, r['level_info'][level]['rows'] - 1].min

          tile_bounds = Bounds.new(tile_coord * tile_spacing * subsample,
                                   (tile_coord * tile_spacing + video_size) * subsample)
          tile_url = "#{root}/#{dataset['id']}/#{level}/#{tile_coord.y}/#{tile_coord.x}.#{tile_format}"

          crop = (bounds - tile_bounds.min) / subsample
          debug << "Tile url: #{tile_url}<br>"
          debug << "Tile crop: #{crop}<br>"
          break
        end
      end
      crop or raise "Didn't find containing tile"

      # ffmpeg ignores negative crop bounds.  So if we have a negative crop bound,
      # pad the upper left and offset the crop
      pad_size = video_size
      pad_tl = Point.new([0, -(crop.min.x.floor)].max,
                         [0, -(crop.min.y.floor)].max)
      crop = crop + pad_tl
      pad_size = pad_size + pad_tl

      # Clamp to max size of the padded area
      cropX = [crop.size.x.to_i, pad_size.x.to_i].min
      cropY = [crop.size.y.to_i, pad_size.y.to_i].min
    end

    #
    # Labels
    #
    #
    label = ''

    if cgi.params.has_key? 'labelsFromDataset' or cgi.params.has_key? 'labels'
      frame_labels = []

      # Label attribute order: color|size|x-pos|y-pos
      label_attributes = (cgi.params.has_key? 'labelAttributes') ? cgi.params['labelAttributes'][0].split("|") : []
      raise "Label attributes specified, but none provided" if label_attributes.empty? and cgi.params.has_key? 'labelAttributes'
      label_color = (label_attributes[0] and !label_attributes[0].empty? and ((label_attributes[0].length == 8 and label_attributes[0].start_with?("0x")) or label_attributes[0] != 'null')) ? label_attributes[0] : "yellow"
      label_size = (label_attributes[1] and !label_attributes[1].empty? and (label_attributes[1].to_i.to_s == label_attributes[1]) and label_attributes[1] != 'null') ? label_attributes[1] : "20"
      label_x_pos = (label_attributes[2] and !label_attributes[2].empty? and (label_attributes[2].to_i.to_s == label_attributes[2]) and label_attributes[2] != 'null') ? (label_attributes[2].to_i - 1) : "9" # by default it has an x-offset of 1
      label_y_pos = (label_attributes[3] and !label_attributes[3].empty? and (label_attributes[3].to_i.to_s == label_attributes[3]) and label_attributes[3] != 'null') ? label_attributes[3] : "12" # really should be 10, but visually 12 appears better

      if cgi.params.has_key? 'labelsFromDataset'
        frame_labels = tm['capture-times']
        raise "Capture times are missing for this dataset" if !frame_labels or frame_labels.empty?
        starting_index = ((time - leader_seconds) * dataset_fps)
        # Truncate to 3 decimal places then take the ceiling
        starting_index = ((starting_index * 1000).floor / 1000.0).ceil
        frame_labels = frame_labels[starting_index, nframes]
        # Auto fit font if the user does not directly specify a size
        if (label_attributes[1].nil? || label_attributes[1].empty? || label_attributes[1] == 'null')
          # output file width - margins (i.e. left margin and always 20 margin on the right)
          allowed_text_area_width = output_width - (label_x_pos.to_i + 20)
          new_font_size = ((0.00000337035 * (allowed_text_area_width ** 3)) - (0.00100792 * (allowed_text_area_width ** 2)) + (0.190542 * allowed_text_area_width) - 1.31804).round
          label_size = [20, new_font_size].min
        end
      else
        txt = cgi.params['labels'][0]
        raise "Need to include at least one label in the list" if txt.empty?
        frame_labels = txt.split("|")
      end

      label += ",\""
      label += "drawtext=fontfile=./DroidSans.ttf:fontsize=#{label_size}:fontcolor=#{label_color}:x=#{label_x_pos}:y=#{label_y_pos}"

      # If we do not have enough labels to cover every frame, ensure that the last label is blank to prevent ffmpeg from
      # repeating the last available label across the remaining frames
      frame_labels << "" if frame_labels.length > 1 and frame_labels.length < nframes

      label_cmds = ''
      frame_length = nframes / desired_fps / nframes
      timestamp = 0
      frame_label_cmd_file = tmpfile + ".cmd"
      frame_labels.each_with_index do |time_text, index|
        # Need to escape colons for ffmpeg
        time_text.gsub!(/\:/, "\\:")
        # Cannot get quotes to work properly, so throw them out so that no ffmpeg errors are raised
        time_text.gsub!(/'|"/, "")
        label += ":text='#{time_text}'" if index == 0
        if index > 0
          label += ",sendcmd=f='#{frame_label_cmd_file}'" if index == 1
          label_cmds += "#{timestamp} drawtext reinit 'text=#{time_text}';"
          timestamp += frame_length
        end
      end
      # We are using sendcmd=f (load commands from file) rather than sendcmd=c (read from commandline) because of the limited
      # number of characters that Windows allows via the commandline, but more generally, because this list can get very long
      # no matter the OS and escaping special chars/spaces in both ffmpeg and ruby-land is also a bit of a nightmare.
      File.open(frame_label_cmd_file, 'w') { |file| file.write(label_cmds) } if frame_labels.length > 1

      label += "\""
    end

    start_dwell_in_sec = cgi.params['startDwell'][0].to_f
    end_dwell_in_sec = cgi.params['endDwell'][0].to_f
    interpolate_frames = cgi.params.has_key?('interpolateBetweenFrames')


    num_start_loop_frames = (desired_fps * start_dwell_in_sec).ceil
    num_end_loop_frames = (desired_fps * end_dwell_in_sec).ceil
    start_loop_frame = 0
    end_loop_frame = nframes + num_start_loop_frames - 1

    input_filters = ""
    if from_screenshot
      input_src = "-f image2 -start_number 0 -i \"#{tmpfile_screenshot_input_path}/%04d.png\" "
    else
      input_src = "-ss #{sprintf('%.3f', time)} -i #{tile_url} -vframes #{nframes}"
      input_filters += "pad=#{pad_size.x}:#{pad_size.y}:#{pad_tl.x}:#{pad_tl.y},crop=#{cropX}:#{cropY}:#{crop.min.x}:#{crop.min.y},"
    end

    cmd = "#{ffmpeg_path} -y #{video_output_fps} #{input_src} -filter_complex \"#{input_filters}scale=#{output_width}:#{output_height}:flags=bicubic#{label}\" -threads #{num_threads}"

    if raw_formats.include? format
      cmd += " -f rawvideo -pix_fmt #{format}"
    end

    if format == 'jpg'
      # compression quality;  lower is higher quality
      #cmd += ' -q:v 2'
      cmd += ' -qscale 2' # older syntax
    end

    collapse = cgi.params.has_key? 'collapse'
    if is_image && nframes != 1 && !collapse
      raise "nframes must be omitted or set to 1 when outputting an image"
    end

    #
    # Insert filter, if any
    #
    #
    filter = cgi.params['filter'][0]
    if filter
      if not /^[\w-]+$/.match(filter)
        raise "Sorry, filter name '#{filter}' must consist only of a-z 0-9 _ -"
      end
      filter_path = filter_dir + "/" + filter
      if not File.exist? filter_path
        raise "Sorry, filter named '#{filter}' does not seem to exist in the filter path"
      end
      # pipe:1 makes ffmpeg output to stdout
      cmd += " pipe:1 | #{filter_path} --width #{output_width} --height #{output_height} > "
      format = 'json' # TODO: can the filter tell us its output format?
    end

    #
    # Animated gif
    #
    #
    if format == 'gif'
      # Note: As of 2012, browsers like Safari and IE do not properly render a gif that is faster than 16fps
      if cgi.params['delay'][0] # the amount of time, in seconds, to wait between frames of the final gif
        delay = cgi.params['delay'][0] + "/1" # in ticks per second
      elsif cgi.params['fps'][0] # the fps of the final gif
        delay = 100 / cgi.params['fps'][0].to_i # in centiseconds
      else
        delay = 20 # default 5 fps
      end
      cmd += " -f image2pipe -vcodec ppm - | /usr/local/bin/gm convert -delay #{delay} -loop 0 - "
    end

    #
    # video (mp4/webm)
    #
    #
    if format == 'mp4'
      cmd += " -vcodec libx264 -preset slow -pix_fmt yuv420p -crf 20 -g 10 -bf 0 -movflags faststart "
    elsif format == 'webm'
      # TODO: These may not be the best webm settings
      cmd += " -qmin 0 -qmax 34 -crf 10 -b:v 1M "
    end

    #
    # Add images into one
    #
    #
    if collapse
      cmd += " -f image2pipe -vcodec ppm - | /usr/local/bin/gm convert -evaluate-sequence min - "
    end

    cmd += " \"#{tmpfile}\""

    debug << "Running: '#{cmd}'<br>"
    output = `#{cmd} 2>&1`;
    if not $?.success?
      debug << "ffmpeg failed with output:<br>"
      debug << "<pre>#{output}</pre>"
      raise "Error executing '#{cmd}'"
    end

    #
    # Post processing filters
    #
    # Really this should be part of the filter chain further up but if for some reason they result in invalid output, we have to do them after the fact...
    #
    # We *could* pipe this into another ffmpeg instance in the main system call above, rather than doing a new system call here, but there are some caveats.
    # The mp4 container cannot write to streams/pipe, it needs to be able to seek back to the beginning of the output to write headers after encoding is finished,
    # so you will get a nice ffmpeg error if you pipe the mp4 out of ffmpeg into another ffmpeg instance. What we can do however is fully fragment the mp4 output
    # with the following flag: '-frag_keyframe+empty_moov' This will cause output to be 100% fragmented, which is what is needed to pipe the output. Without this flag,
    # the first fragment will be muxed as a short movie (using moov) followed by the rest of the media in fragments, which results in the inability to pipe to another ffmpeg.
    #
    post_process_filters = ""

    # Dwell time filter
    post_process_filters += "loop=#{num_start_loop_frames}:1:#{start_loop_frame},setpts=N/FRAME_RATE/TB," if start_dwell_in_sec > 0 and (format == 'gif' or is_video)
    post_process_filters += "loop=#{num_end_loop_frames}:1:#{end_loop_frame},setpts=N/FRAME_RATE/TB," if end_dwell_in_sec > 0 and (format == 'gif' or is_video)

    # 'Fader shader' filter
    post_process_filters += "minterpolate='mi_mode=mci:mc_mode=aobmc:vsbmc=1:fps=60'," if interpolate_frames and (format == 'gif' or is_video)

    post_process_filters.chomp!(',')
    unless post_process_filters.empty?
      tmpfile_postprocess = "#{cache_file}.tmp-#{Process.pid}-pp.#{format}"
      cmd = "#{ffmpeg_path} -y -i #{tmpfile} -filter_complex \"#{post_process_filters}\" -threads #{num_threads} \"#{tmpfile_postprocess}\""
      debug << "Running post process filters: '#{cmd}'<br>"
      output = `#{cmd} 2>&1`;
      if not $?.success?
        debug << "ffmpeg failed with output:<br>"
        debug << "<pre>#{output}</pre>"
        raise "Error executing '#{cmd}'"
      end
      File.delete(tmpfile)
      tmpfile = tmpfile_postprocess
    end

    image_data = open(tmpfile, 'rb') {|i| i.read}
    $stats['sizeBytes'] = image_data.size
    $stats['totalTimeSecs'] = Time.now - $begin_time
    pt = Process.times
    $stats['cpuTime'] = pt.utime + pt.stime + pt.cutime + pt.cstime
    vlog(0, "ENDTHUMBNAIL #{$request_url} #{JSON.generate($stats)}")

    if cache_file
      File.rename tmpfile, cache_file
      vlog(0, "Moved output file to cache: #{cache_file}")
    else
      vlog(0, "Deleted output file");
      File.unlink tmpfile
    end

    # Cleanup screenshot work
    if from_screenshot
      FileUtils.rm_rf(tmpfile_screenshot_input_path)
    end

    #
    # Done
    #
  end

  debug_mode = cgi.params.has_key? 'debug'

  if debug_mode
    debug << "</body></html>"
    cgi.out {debug.join('')}
  elsif not cache_file
    print image_data
    exit
  else
    mime_types = {
      'gif' => 'image/gif',
      'jpg' => 'image/jpeg',
      'json' => 'application/json',
      'mp4' => 'video/mp4',
      'webm' => 'video/webm',
      'png' => 'image/png'
    }
    mime_type = mime_types[format] || 'application/octet-stream'
    cgi.out('type' => mime_type, 'Access-Control-Allow-Origin' => '*') {image_data}
  end

rescue SystemExit
  # ignore
rescue Exception => e
  debug.insert 0, "400: Bad Request<br>"
  debug.insert 2, "<pre>#{e}\n#{e.backtrace.join("\n")}</pre>"
  debug.insert 3, "<hr>"
  cgi.out('status' => 'BAD_REQUEST', 'Access-Control-Allow-Origin' => '*') {debug.join('')}
end

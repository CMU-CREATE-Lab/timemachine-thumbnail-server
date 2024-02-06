#!/usr/bin/env ruby

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
require 'net/http'
require 'selenium-webdriver'
require 'rack'

load File.dirname(File.realpath(__FILE__)) + '/mercator.rb'
load File.dirname(File.realpath(__FILE__)) + '/point.rb'
load File.dirname(File.realpath(__FILE__)) + '/bounds.rb'
load File.dirname(File.realpath(__FILE__)) + '/FlockSemaphore.rb'
load File.dirname(File.realpath(__FILE__)) + '/stat.rb'

filter_dir = File.dirname(File.realpath(__FILE__)) + '/filters'

$ffmpeg_path = '/usr/local/bin/ffmpeg'
$graphics_magick_path = '/usr/bin/gm convert'
$num_threads = 8

config_path = File.dirname(File.realpath(__FILE__)) + '/config.json'
if File.exists? config_path
  $config = open(config_path) {|i| JSON.parse(i.read)}
else
  $config = {}
end

$lockdir = nil
if $config['lockdir']
  $lockdir = $config['lockdir']
else
  default_lockdir = File.dirname(File.dirname(File.realpath(__FILE__))) + '/locks'
  if File.exists? default_lockdir
    $lockdir = default_lockdir
  end
end

$vlog_logfile = File.open(File.dirname(File.dirname(File.realpath(__FILE__))) + '/log.txt' , 'a')
$id = "%06d" % rand(1000000)
$stats = {}

def vlog(shardno, msg)
  $vlog_logfile.write("#{Time.now.strftime('%Y-%m-%d %H:%M:%S.%3N')} THUMB #{Process.pid}:#{$id}:#{shardno} #{msg}\n")
  $vlog_logfile.flush
end

Stat.set_hostname('-')
Stat.set_service('Thumbnails')

cgi = CGI.new
cgi.params = CGI::parse(ENV.to_hash['REQUEST_URI'])
cgi.params['root'] = cgi.params.delete('/thumbnail?root')

$debug = []

def parse_bounds(cgi, key)
  if not cgi.params.has_key?(key)
    return false
  end
  bounds = cgi.params[key][-1].gsub("02C", ",").split(',').map(&:to_f)
  bounds.size == 4 or raise "#{key} was specified without the required 4 coords separated by commas"
  bounds
end

# Version 0: old ad-hoc API (before actual API)
# Version 1: first release of API (before reporting version numbers)
# Version 2: first release of API supporting version number
$api_version = 0

class ThumbnailGenerator
  def initialize()
    # cache and tmp live in the containing directory
    @cache_dir = File.dirname(File.dirname(File.realpath(__FILE__))) + '/cache'
    @tmp_dir = File.dirname(File.dirname(File.realpath(__FILE__))) + '/tmp'
  end

  def make_chrome(shardno, url)
    before = Time.now
    options = Selenium::WebDriver::Chrome::Options.new
    options.add_argument('--headless')
    options.add_argument('--hide-scrollbars')
    if File.exists?('/.dockerenv')
      options.add_argument('--disable-gpu')
      options.add_argument('--no-sandbox')
      options.add_argument('--disable-dev-shm-usage')
    end
    driver = Selenium::WebDriver.for :chrome, options: options
    if $config['override_headless']
      url = url.sub('headless.earthtime.org', $config['override_headless'])
    end
    url += '&pauseWhenInitialized=true'
    url += '&disableAnimation=true'
    vlog(shardno, "make_chrome loading #{url}")

    # Resize the window to desired width/height.
    driver.manage.window.resize_to(@output_width, @output_height)

    5.times do |j|
      # Navigate to the page; will block until the load is complete.
      # Note: Any ajax requests or large data files may not be loaded yet.
      #       We take care of that further down when taking the actual screenshots.
      driver.navigate.to url
      # TODO: actually wait until all the layers are loaded, and then record how long that took
      200.times do |i|
        # Return false if not yet ready.  Otherwise, return api version #.
        api_version = driver.execute_script(%{
          if (window.gFrameGrab) {
            if (!window.gFrameGrab.isLoaded()) return false;
            return window.gFrameGrab.apiVersion || 1; // version 1 if no version is reported
          } else if (window.isEarthTimeLoaded) {
            if (!window.isEarthTimeLoaded()) return false;
            return 0; // version 0 is pre-API
          } else {
            return false;
          }
        })
        vlog(shardno, "#{i}: isLoaded=#{api_version}")
        if api_version != false
          # We're done and have set $api_version;  return
          $api_version = api_version
          vlog(shardno, "make_chrome took #{((Time.now - before) * 1000).round} ms, api_version=#{$api_version}")
          return driver
        end
        sleep(0.5)
      end

      vlog(shardno, "#{j}: make_chrome was never ready, retrying")
      driver.navigate.refresh
    end
    vlog(shardno, "Oh gosh, failed many times to initialize chrome, aborting")
    raise "Oh gosh, failed many times to initialize chrome, aborting"
  end

  def set_status(token)
    if $statusfile
      $statusfile.close()
    end
    if token
      $statusfile = File.open("#{File.dirname(File.realpath(__FILE__))}/status-#{token}")
    end
  end

  def acquire_screenshot_semaphore()
    if $lockdir
      @semaphore = FlockSemaphore.new($lockdir)
      set_status('waiting')
      while true
        lock = @semaphore.captureNonblock
        if lock
          vlog(0, "Captured resource lock #{lock} from #{$lockdir}")
          break
        else
          vlog(0, "Waiting to capture resource lock in #{$lockdir}")
        end
        sleep(1)
      end
      set_status(nil)
      thumbnail_worker_hostname = File.basename(lock).split('+')[1]
      vlog(0, "Thumbnail worker #{thumbnail_worker_hostname}")
      return thumbnail_worker_hostname
    else
      @semaphore = nil
      vlog(0, "No lockdir; skipping semaphore capture")
      return 'localhost'
    end
  end

  def start_thumbnail_from_screenshot()

    Selenium::WebDriver.logger.output = STDERR
    #Selenium::WebDriver.logger.level = :info

    def queue_pop_nonblock(queue)
      begin
        return queue.pop(non_block=true)
      rescue ThreadError
        return nil
      end
    end

    # Convert URL encoded characters back to their original values
    @root.gsub!("03D", "=")
    @root.gsub!("02C", ",")
    # Mistakes were made when hex values were chosen for # and &
    # We have to do extra work do convert them back and ensure that we
    # do not accidently convert real sequences of these digits
    @root.scan(/026\w+=/).each do |m|
      @root.gsub!(m, m.gsub("026", "&"))
    end
    @root.scan(/023\w+=/).each do |m|
      @root.gsub!(m, m.gsub("026", "#"))
    end

    # Add the correct delimiter to the end, in preparation for UI type
    @root += @root.include?("#") ? "&" : "#"

    screenshot_from_video = @root.include?("blsat")
    vlog(0, "root #{@root}")
    root_url_params = CGI::parse(@root.split('#')[1])
    vlog(0, "root_url_params #{root_url_params}")

    # We've already added a trailing delim, add UI type without a delim
    if @cgi.params.has_key?('minimalUI')
      @root += "minimalUI=true"
    elsif @cgi.params.has_key?('legendOnlyUI')
      @root += "forceLegend=true"
      @root += "&disableUI=true"
    elsif @cgi.params.has_key?('timestampOnlyUILeft')
      @root += "timestampOnlyUILeft=true"
    elsif @cgi.params.has_key?('timestampOnlyUI')
      @root += "timestampOnlyUI=true"
      @root += '&timestampOnlyUICentered=true'
    else
      @root += "disableUI=true"
    end

    # Any new parameters after this point need a "&" delimeter

    if @cgi.params.has_key?('baseMapsNoLabels')
      @root += '&baseMapsNoLabels=true'
    end

    if @cgi.params.has_key?('centerLegend')
      @root += '&centerLegend=true'
    end

    @output_width = @cgi.params['width'][0].to_i || 128
    @output_height = @cgi.params['height'][0].to_i || 74

    #
    # Parse bounds
    #

    @screenshot_bounds = {}
    if @boundsFromSharelink
      view = root_url_params['v'][0].split(',')
      if view[-1] == 'pts'
        @screenshot_bounds = {'bbox' => {'xmin' => view[0].to_f, 'ymin' => view[1].to_f}, 'xmax' => view[2].to_f, 'ymax' => view[3].to_f}
      elsif view[-1] == 'latLng'
        @screenshot_bounds = {'center' => {'lat' => view[0].to_f, 'lng' => view[1].to_f}, 'zoom' => view[2].to_f}
      else
        vlog(0, 'boundsFromSharelink parsing failed')
        raise 'boundsFromSharelink parsing failed'
      end
    elsif @boundsNWSE
      @screenshot_bounds['bbox'] = {}
      @screenshot_bounds['bbox']['ne'] = {'lat' => @boundsNWSE[0], 'lng' => @boundsNWSE[1]}
      @screenshot_bounds['bbox']['sw'] = {'lat' => @boundsNWSE[2], 'lng' => @boundsNWSE[3]}
    else
      @screenshot_bounds['bbox'] = {}
      @screenshot_bounds['bbox']['xmin'] = @boundsLTRB[0]
      @screenshot_bounds['bbox']['ymin'] = @boundsLTRB[1]
      @screenshot_bounds['bbox']['xmax'] = @boundsLTRB[2]
      @screenshot_bounds['bbox']['ymax'] = @boundsLTRB[3]
    end
    vlog(0, "screenshot_bounds #{@screenshot_bounds}")

    $stats['headless_root'] = @root
    driver = make_chrome(0, @root)
    @first_driver = driver
    vlog(0, "CHECKPOINTTHUMBNAIL CHROMERUNNING #{JSON.generate($stats)}")

    # 0 - 100.  If ps is missing or set to zero, override to 50
    @screenshot_playback_speed = root_url_params.has_key?('ps') ? root_url_params['ps'][0].to_f : 50.0
    if @screenshot_playback_speed < 1e-10
      @screenshot_playback_speed = 50.0
    end

    # bt and et could be specified as seconds in playback time, or could be specified as dates in YYYYMMDD[HH[MM[SS]]]
    # or they could be omitted


    # Find bt, and replace with 0 if not present
    screenshot_begin_time_as_date = root_url_params.has_key?('bt') ? root_url_params['bt'][0] : 0.0
    # Find bt, and replace with end playback time (in seconds) if not present
    if $api_version >= 2
      screenshot_end_time_as_date = root_url_params.has_key?('et') ? root_url_params['et'][0] : driver.execute_script("return gFrameGrab.getEndPlaybackTime();").to_f
    else
      screenshot_end_time_as_date = root_url_params.has_key?('et') ? root_url_params['et'][0] : driver.execute_script("return timelapse.getDuration();").to_d.truncate(1).to_f
    end

    $debug << "screenshot_playback_speed: #{@screenshot_playback_speed}<br>"
    $debug << "screenshot_begin_time_as_date #{screenshot_begin_time_as_date}<br>"
    $debug << "screenshot_end_time_as_date #{screenshot_end_time_as_date}<br>"

    # Call api to parse begin/end times in case they are in YYYYMMDD[HH[MM[SS]]] format.  (Will pass through unchanged if already in seconds of playback time)
    if $api_version >= 2
      @screenshot_begin_time_as_render_time = driver.execute_script("return gFrameGrab.getPlaybackTimeFromStringDate('#{screenshot_begin_time_as_date}')").to_f
      @screenshot_end_time_as_render_time = driver.execute_script("return gFrameGrab.getPlaybackTimeFromStringDate('#{screenshot_end_time_as_date}')").to_f
      vlog(0, "getPlaybackTimeFromStringDate #{screenshot_begin_time_as_date} -> #{@screenshot_begin_time_as_render_time}")
      vlog(0, "getPlaybackTimeFromStringDate #{screenshot_end_time_as_date} -> #{@screenshot_end_time_as_render_time}")
    else
      @screenshot_begin_time_as_render_time = driver.execute_script("return timelapse.playbackTimeFromShareDate('#{screenshot_begin_time_as_date}')").to_f
      @screenshot_end_time_as_render_time = driver.execute_script("return timelapse.playbackTimeFromShareDate('#{screenshot_end_time_as_date}')").to_f
    end

    $debug << "screenshot_begin_time_as_render_time: #{@screenshot_begin_time_as_render_time}<br>"
    $debug << "screenshot_end_time_as_render_time: #{@screenshot_end_time_as_render_time}<br>"

    @dataset_num_frames = driver.execute_script("return timelapse.getNumFrames();").to_f
    @dataset_fps = driver.execute_script("return timelapse.getFps();").to_f
    @viewer_max_playback_rate = driver.execute_script("return timelapse.getMaxPlaybackRate();").to_f

    $debug << "viewer_max_playback_rate: #{@viewer_max_playback_rate}<br>"
  end

  #########################


  def start_thumbnail_not_screenshot()
    #
    # Fetch tm.json
    #

    tm_url = "#{@root}/tm.json"
    $debug << "tm_url: #{tm_url}<br>"
    @tm = open(tm_url) {|i| JSON.parse(i.read)}
    $debug << JSON.dump(@tm)
    $debug << "<hr>"

    # Use first dataset if there are multiple
    @dataset = @tm['datasets'][0]

    #
    # Fetch r.json
    #

    r_url = "#{@root}/#{@dataset['id']}/r.json"
    $debug << "r_url: #{r_url}<br>"
    @r = open(r_url) {|i| JSON.parse(i.read)}
    $debug << JSON.dump(@r)
    $debug << "<br>"

    @dataset_num_frames = @r['frames'].to_f
    @dataset_fps = @r['fps'].to_f
    @nframes = [@nframes, @dataset_num_frames].min

    #
    # Parse bounds
    #

    timemachine_width = @r['width']
    timemachine_height = @r['height']
    $debug << "timemachine dims: #{timemachine_width} x #{timemachine_height}<br>"

    if @boundsNWSE
      projection_bounds = @tm['projection-bounds'] or raise "boundsNWSE were specified, but #{tm_url} is missing projection-bounds"

      projection = MercatorProjection.new(projection_bounds, timemachine_width, timemachine_height)
      $debug << "projection-bounds: #{JSON.dump(projection_bounds)}<br>"

      $debug << "boundsNWSE: #{@boundsNWSE.join(', ')}<br>"
      ne = projection.latlngToPoint({'lat' => @boundsNWSE[0], 'lng' => @boundsNWSE[1]})
      sw = projection.latlngToPoint({'lat' => @boundsNWSE[2], 'lng' => @boundsNWSE[3]})

      @bounds = Bounds.new(Point.new(ne['x'], ne['y']), Point.new(sw['x'], sw['y']))

    else
      @bounds = Bounds.new(Point.new(@boundsLTRB[0], @boundsLTRB[1]),
                          Point.new(@boundsLTRB[2], @boundsLTRB[3]))
    end

    @input_aspect_ratio = @bounds.size.x.to_f / @bounds.size.y
    $debug << "bounds: #{@bounds}<br>"
  end

  #################################

  def capture_frames_from_screenshot()
    begin
      total_chrome_frames = 0

      @tmpfile_screenshot_input_path = "#{@tmp_dir}/screenshots.#{Process.pid}.#{(Time.now.to_f)}"
      FileUtils.mkdir_p(@tmpfile_screenshot_input_path) unless File.exists?(@tmpfile_screenshot_input_path)

      screenshot_playback_rate = (100.0 / @screenshot_playback_speed)
      video_duration_in_secs = (@screenshot_end_time_as_render_time - @screenshot_begin_time_as_render_time) /  (@viewer_max_playback_rate / screenshot_playback_rate)
      vlog(0, "video_duration_in_secs #{video_duration_in_secs}")
      vlog(0, "@screenshot_begin_time_as_render_time #{@screenshot_begin_time_as_render_time} @screenshot_end_time_as_render_time #{@screenshot_end_time_as_render_time}")
      vlog(0, "@viewer_max_playback_rate #{@viewer_max_playback_rate} screenshot_playback_rate #{screenshot_playback_rate}")

      @nframes = @is_image ? 1 : (video_duration_in_secs * @desired_fps).ceil
      vlog(0, "@nframes #{@nframes} @desired_fps #{@desired_fps}")

      if @nframes < 1
        @nframes = 1
      end

      vlog(0, "Need to compute #{@nframes} frames")

      if @nframes > 10000
        vlog(0, "Too many frames to compute #{@nframes}")
        raise "Too many frames to compute #{@nframes}"
      end

      frame_queue = Queue.new
      (0 ... @nframes).each { |i| frame_queue << i }

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
              driver = make_chrome(shardno, @root)
              frame = queue_pop_nonblock(frame_queue)
              if frame == nil
                break
              end
            end
            seek_time = (frame.to_f / [1.0, (@nframes.to_f - 1.0)].max) * (@screenshot_end_time_as_render_time - @screenshot_begin_time_as_render_time) + @screenshot_begin_time_as_render_time
            seek_time = seek_time.round(4)
            $debug << "frame #{frame} seeking to: #{seek_time}<br>"
            vlog(shardno, "frame #{frame} seeking to: #{seek_time}")

            before = Time.now
            driver.execute_script("timelapse.seek(#{seek_time});")

            while true do
              # Wait at most 180 seconds until we assume things are drawn
              if (Time.now - before) > 180
                vlog(shardno, "giving up on frame #{frame} after #{((Time.now - before) * 1000).round}ms; stopping driver")
                frame_queue << frame
                total_chrome_frames += driver.execute_script("return timelapse.frameno")
                driver.quit
                driver = nil
                break
              end
              if $api_version >= 1
                frame_state = {"bounds"=>@screenshot_bounds, "seek_time"=>seek_time}
                framegrab_info = driver.execute_script(
                  "return gFrameGrab.captureFrame(#{frame_state.to_json});"
                )
                complete = framegrab_info['complete']
                after_time = framegrab_info['after_time']
                before_frameno = framegrab_info['before_frameno']
                frameno = framegrab_info['frameno']
                @aux_info = framegrab_info['aux_info']
                vlog(shardno, "complete=#{complete} seek_time=#{seek_time} after_time=#{after_time} before_frameno=#{before_frameno} frameno=#{frameno}")
                if @aux_info
                  vlog(shardno, "aux_info: #{@aux_info}")
                end
              else
                (complete, after_time, before_frameno, frameno) = driver.execute_script(
                "{" +
                "var before_frameno = timelapse.frameno;" +
                "timelapse.setNewView(#{@screenshot_bounds.to_json}, true);" +
                "timelapse.seek(#{seek_time});" +
                "canvasLayer.update_();" +
                "return [timelapse.lastFrameCompletelyDrawn, timelapse.getCurrentTime(), before_frameno, timelapse.frameno];" +
                "}"
              )
              end
              if complete
                if @legendHTML
                  @legendContent = driver.execute_script(%Q(
                    return {
                      HTML: getLegendHTML(),
                      width:  $('#layers-legend').width(),
                      height: $('#layers-legend').height()
                    };))
                else
                  screenshot_path = "#{@tmpfile_screenshot_input_path}/#{'%04d' % frame}.png"
                  driver.save_screenshot(screenshot_path)
                  vlog(shardno, "size of screenshot is #{File.size(screenshot_path)}")
                end
                vlog(shardno, "frame #{frame} took #{((Time.now - before) * 1000).round} ms (chrome frame #{frameno})");
                break
              else
                vlog(shardno, "frame #{frame} called update but not ready yet (chrome frame #{frameno})")
                sleep(0.05)
              end
            end
          end
          vlog(shardno, "Shard finished");
          if driver then
            total_chrome_frames += driver.execute_script("return timelapse.frameno || 1")
            driver.quit
          end
        }
      }

      nshards = (@nframes / 10).floor
      if nshards < 1
        nshards = 1
      end
      if nshards > 5
        nshards = 5
      end

      $stats['nshards'] = nshards

      shard_threads = []

      (0 ... nshards).each do |shardno|
        if shardno == 0
          # Reuse the first driver
          thread_driver = @first_driver
        else
          thread_driver = nil
        end
        shard_threads << new_capture_frames_thread.call(shardno, thread_driver)
      end

      shard_threads.each { |shard_thread| shard_thread.join }

      vlog(0, "Chrome rendered a total of #{total_chrome_frames} frames, for #{@nframes} frames needed (#{"%.1f" % (@nframes * 100.0 / total_chrome_frames)}%)")

      $stats['chromeRenderTimeSecs'] = Time.now - $begin_time
      $stats['videoFrameCount'] = @nframes
      $stats['frameEfficiency'] = @nframes.to_f / total_chrome_frames
      vlog(0, "CHECKPOINTTHUMBNAIL CHROMEFINISHED #{JSON.generate($stats)}")
    rescue Selenium::WebDriver::Error::TimeoutError
      raise "Error taking screenshot. Data failed to load."
    end
    if @semaphore
      @semaphore.release
    end
  end

  def find_tile_for_non_screenshot()
    #
    # Search for tile from the tile tree
    #

    @tile_url = @crop = nil

    output_subsample = [@bounds.size.x / @output_width, @bounds.size.y / @output_height].max

    $debug << "output_subsample: #{output_subsample}<br>"

    # ffmpeg refuses to subsample more than this?
    maximum_ffmpeg_subsample = 64

    tile_spacing = Point.new(@r['tile_width'], @r['tile_height'])
    video_size = Point.new(@r['video_width'], @r['video_height'])

    # Start from highest level (most detailed) and "zoom out" until a tile is found
    # to completely cover the requested area
    @r['nlevels'].times do |i|
      subsample = 1 << i
      tile_coord = (@bounds.min / subsample / tile_spacing).floor
      level = @r['nlevels'] - i - 1

      # Reject level if it would require subsampling more than ffmpeg allows
      required_subsample = output_subsample / subsample
      if required_subsample > maximum_ffmpeg_subsample
        $debug << "level #{level} would have required tile to be subsampled by #{required_subsample}, rejecting<br>"
        next
      end

      tile_bounds = Bounds.new(tile_coord * tile_spacing * subsample,
                               (tile_coord * tile_spacing + video_size) * subsample)

      @tile_url = "#{@root}/#{@dataset['id']}/#{level}/#{tile_coord.y}/#{tile_coord.x}.#{@tile_format}"
      $debug << "subsample #{subsample}, tile #{tile_bounds} #{@tile_url} contains #{@bounds}? #{tile_bounds.contains @bounds}<br>"
      if tile_bounds.contains @bounds or level == 0
        $debug << "Best tile: #{tile_coord}, level: #{level} (subsample: #{subsample})<br>"

        tile_coord.x = [tile_coord.x, 0].max
        tile_coord.y = [tile_coord.y, 0].max
        tile_coord.x = [tile_coord.x, @r['level_info'][level]['cols'] - 1].min
        tile_coord.y = [tile_coord.y, @r['level_info'][level]['rows'] - 1].min

        tile_bounds = Bounds.new(tile_coord * tile_spacing * subsample,
                                 (tile_coord * tile_spacing + video_size) * subsample)
        @tile_url = "#{@root}/#{@dataset['id']}/#{level}/#{tile_coord.y}/#{tile_coord.x}.#{@tile_format}"

        @crop = (@bounds - tile_bounds.min) / subsample
        $debug << "Tile url: #{@tile_url}<br>"
        $debug << "Tile crop: #{@crop}<br>"
        break
      end
    end
    @crop or raise "Didn't find containing tile"

    # ffmpeg ignores negative crop bounds.  So if we have a negative crop bound,
    # pad the upper left and offset the crop
    @pad_size = video_size
    @pad_tl = Point.new([0, -(@crop.min.x.floor)].max,
                       [0, -(@crop.min.y.floor)].max)
    @crop = @crop + @pad_tl
    @pad_size = @pad_size + @pad_tl

    # Clamp to max size of the padded area
    @cropX = [@crop.size.x.to_i, @pad_size.x.to_i].min
    @cropY = [@crop.size.y.to_i, @pad_size.y.to_i].min
  end

  def encode_frames()
    #
    # Labels
    #
    #
    label = ''

    if @cgi.params.has_key? 'labelsFromDataset' or @cgi.params.has_key? 'labels'
      frame_labels = []

      # Label attribute order: color|size|x-pos|y-pos
      label_attributes = (@cgi.params.has_key? 'labelAttributes') ? @cgi.params['labelAttributes'][0].split("|") : []
      raise "Label attributes specified, but none provided" if label_attributes.empty? and @cgi.params.has_key? 'labelAttributes'
      label_color = (label_attributes[0] and !label_attributes[0].empty? and ((label_attributes[0].length == 8 and label_attributes[0].start_with?("0x")) or label_attributes[0] != 'null')) ? label_attributes[0] : "yellow"
      label_size = (label_attributes[1] and !label_attributes[1].empty? and (label_attributes[1].to_i.to_s == label_attributes[1]) and label_attributes[1] != 'null') ? label_attributes[1] : "20"
      label_x_pos = (label_attributes[2] and !label_attributes[2].empty? and (label_attributes[2].to_i.to_s == label_attributes[2]) and label_attributes[2] != 'null') ? (label_attributes[2].to_i - 1) : "9" # by default it has an x-offset of 1
      label_y_pos = (label_attributes[3] and !label_attributes[3].empty? and (label_attributes[3].to_i.to_s == label_attributes[3]) and label_attributes[3] != 'null') ? label_attributes[3] : "12" # really should be 10, but visually 12 appears better

      if @cgi.params.has_key? 'labelsFromDataset'
        frame_labels = @tm['capture-times']
        raise "Capture times are missing for this dataset" if !frame_labels or frame_labels.empty?
        starting_index = ((@time - @leader_seconds) * @dataset_fps)
        # Truncate to 3 decimal places then take the ceiling
        starting_index = ((starting_index * 1000).floor / 1000.0).ceil
        frame_labels = frame_labels[starting_index, @nframes]
        # Auto fit font if the user does not directly specify a size
        if (label_attributes[1].nil? || label_attributes[1].empty? || label_attributes[1] == 'null')
          # output file width - margins (i.e. left margin and always 20 margin on the right)
          allowed_text_area_width = @output_width - (label_x_pos.to_i + 20)
          new_font_size = ((0.00000337035 * (allowed_text_area_width ** 3)) - (0.00100792 * (allowed_text_area_width ** 2)) + (0.190542 * allowed_text_area_width) - 1.31804).round
          label_size = [20, new_font_size].min
        end
      else
        txt = @cgi.params['labels'][0]
        raise "Need to include at least one label in the list" if txt.empty?
        frame_labels = txt.split("|")
      end

      label += ","
      label += "drawtext=fontfile=./fonts/DroidSans.ttf:fontsize=#{label_size}:fontcolor=#{label_color}:x=#{label_x_pos}:y=#{label_y_pos}"

      # If we do not have enough labels to cover every frame, ensure that the last label is blank to prevent ffmpeg from
      # repeating the last available label across the remaining frames
      frame_labels << "" if frame_labels.length > 1 and frame_labels.length < @nframes

      label_cmds = ''
      frame_length = @nframes / @desired_fps / @nframes
      timestamp = 0
      frame_label_cmd_file = @tmpfile + ".cmd"
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
    end

    # TODO: Add watermarkAttributes param to allow for style customization
    # TODO: The -18 in height for every new row is dependent on the font and font size
    if @cgi.params.has_key? 'watermark'
      @cgi.params['watermark'][0].split("|").each_with_index do |text_line, idx|
        label += ",drawtext=fontfile=./fonts/WorkSans-Bold.ttf:text='#{text_line}':fontsize=14:fontcolor=white@0.30:borderw=1:bordercolor=black@0.25:x=w-tw-4:y=h-th-4-#{idx*18}"
      end
    end

    start_dwell_in_sec = @cgi.params['startDwell'][0].to_f
    end_dwell_in_sec = @cgi.params['endDwell'][0].to_f
    interpolate_frames = @cgi.params.has_key?('interpolateBetweenFrames')


    num_start_loop_frames = (@desired_fps * start_dwell_in_sec).ceil
    num_end_loop_frames = (@desired_fps * end_dwell_in_sec).ceil
    start_loop_frame = 0
    end_loop_frame = @nframes + num_start_loop_frames - 1

    input_filters = ""
    if @from_screenshot
      input_src = "-f image2 -start_number 0 -i \"#{@tmpfile_screenshot_input_path}/%04d.png\" "
    else
      input_src = "-ss #{sprintf('%.3f', @time)} -i #{@tile_url} -vframes #{@nframes}"
      input_filters += "pad=#{@pad_size.x}:#{@pad_size.y}:#{@pad_tl.x}:#{@pad_tl.y},crop=#{@cropX}:#{@cropY}:#{@crop.min.x}:#{@crop.min.y},"
    end

    cmd = "#{$ffmpeg_path} -y #{@video_output_fps} #{input_src} -filter_complex \"#{input_filters}scale=#{@output_width}:#{@output_height}:flags=bicubic#{label}\" -threads #{$num_threads}"

    if @raw_formats.include? @format
      cmd += " -f rawvideo -pix_fmt #{@format}"
    end

    if @format == 'jpg'
      # compression quality;  lower is higher quality
      #cmd += ' -q:v 2'
      cmd += ' -qscale 2' # older syntax
    end

    collapse = @cgi.params.has_key? 'collapse'
    if @is_image && @nframes != 1 && !collapse
      raise "nframes must be omitted or set to 1 when outputting an image"
    end

    #
    # Insert filter, if any
    #
    #
    filter = @cgi.params['filter'][0]
    if filter
      if not /^[\w-]+$/.match(filter)
        raise "Sorry, filter name '#{filter}' must consist only of a-z 0-9 _ -"
      end
      filter_path = filter_dir + "/" + filter
      if not File.exist? filter_path
        raise "Sorry, filter named '#{filter}' does not seem to exist in the filter path"
      end
      # pipe:1 makes ffmpeg output to stdout
      cmd += " pipe:1 | #{filter_path} --width #{@output_width} --height #{@output_height} > "
      @format = 'json' # TODO: can the filter tell us its output format?
    end

    #
    # Animated gif
    #
    #
    if @format == 'gif'
      # Note: As of 2012, browsers like Safari and IE do not properly render a gif that is faster than 16fps
      if @cgi.params['delay'][0] # the amount of time, in seconds, to wait between frames of the final gif
        delay = @cgi.params['delay'][0] + "/1" # in ticks per second
      elsif @cgi.params['fps'][0] # the fps of the final gif
        delay = 100 / @cgi.params['fps'][0].to_i # in centiseconds
      else
        delay = 20 # default 5 fps
      end
      cmd += " -f image2pipe -vcodec ppm - | #{$graphics_magick_path} -delay #{delay} -loop 0 - "
    end

    #
    # Zip of png frames
    #
    if @format == 'zip'
      @tmpfile_zip_dir = "#{@tmp_dir}/zip.#{Process.pid}.#{(Time.now.to_f)}"
      FileUtils.mkdir_p("#{@tmpfile_zip_dir}/frames")
      cmd += " #{@tmpfile_zip_dir}/frames/frame%06d.png && (cd #{@tmpfile_zip_dir} && zip -r \"#{@tmpfile}\" frames)"
    end

    #
    # video (mp4/webm)
    #
    #
    if @format == 'mp4'
      cmd += " -vcodec libx264 -preset slow -pix_fmt yuv420p -crf 20 -g 10 -bf 0 -movflags faststart "
    elsif @format == 'webm'
      # TODO: These may not be the best webm settings
      cmd += " -qmin 0 -qmax 34 -crf 10 -b:v 1M "
    end

    #
    # Add images into one
    #
    #
    if collapse
      cmd += " -f image2pipe -vcodec ppm - | #{$graphics_magick_path} -evaluate-sequence min - "
    end

    if @format != 'zip'
      cmd += " \"#{@tmpfile}\""
    end

    $debug << "Running: '#{cmd}'<br>"
    output = `#{cmd} 2>&1`;

    if not $?.success?
      $debug << "ffmpeg failed with output:<br>"
      $debug << "<pre>#{output}</pre>"
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
    post_process_filters += "loop=#{num_start_loop_frames}:1:#{start_loop_frame},setpts=N/FRAME_RATE/TB," if start_dwell_in_sec > 0 and (@format == 'gif' or @is_video)
    post_process_filters += "loop=#{num_end_loop_frames}:1:#{end_loop_frame},setpts=N/FRAME_RATE/TB," if end_dwell_in_sec > 0 and (@format == 'gif' or @is_video)

    # 'Fader shader' filter
    post_process_filters += "minterpolate='mi_mode=mci:mc_mode=aobmc:vsbmc=1:fps=60'," if interpolate_frames and (@format == 'gif' or @is_video)

    post_process_filters.chomp!(',')
    unless post_process_filters.empty?
      tmpfile_postprocess = "#{@tmp_dir}/#{Process.pid}.#{(Time.now.to_f)}-pp.#{@format}"
      cmd = "#{$ffmpeg_path} -y -i #{@tmpfile} -filter_complex \"#{post_process_filters}\" -threads #{$num_threads} \"#{tmpfile_postprocess}\""
      $debug << "Running post process filters: '#{cmd}'<br>"
      output = `#{cmd} 2>&1`;
      if not $?.success?
        $debug << "ffmpeg failed with output:<br>"
        $debug << "<pre>#{output}</pre>"
        raise "Error executing '#{cmd}'"
      end
      File.delete(@tmpfile)
      @tmpfile = tmpfile_postprocess
    end
  end


  def compute_thumbnail()
    @boundsNWSE = parse_bounds(@cgi, 'boundsNWSE')
    @boundsLTRB = parse_bounds(@cgi, 'boundsLTRB')
    if !@boundsNWSE and !@boundsLTRB
      if @from_screenshot
        @boundsFromSharelink = true
      else
        raise "Must specify boundsNWSE or boundsLTRB, unless fromScreenshot"
      end
    else
      if @boundsNWSE and @boundsLTRB
        raise "Both boundsNWSE and boundsLTRB were specified;  please specify only one"
      end
    end

    if @from_screenshot
      start_thumbnail_from_screenshot()
    else
      start_thumbnail_not_screenshot()
    end

    #
    # Requested output size
    #

    @output_width = @cgi.params['width'][0]
    @output_width &&= @output_width.to_i
    @output_height = @cgi.params['height'][0]
    @output_height &&= @output_height.to_i

    ignore_aspect_ratio = @cgi.params.has_key? 'ignoreAspectRatio'

    if !@output_width && !@output_height
      raise "Must specify at least one of 'width' and 'height'"
    elsif @output_width && @output_height
      if  !ignore_aspect_ratio
        #
        # output aspect ratio was specified.  Tweak input bounds to match output aspect ratio, by selecting
        # new bounds with the same center and area as original.
        #
        output_aspect_ratio = @output_width.to_f / @output_height
        if not @from_screenshot
          aspect_factor = Math.sqrt(output_aspect_ratio / @input_aspect_ratio)
          @bounds = Bounds.with_center(@bounds.center,
                                    Point.new(@bounds.size.x * aspect_factor, @bounds.size.y / aspect_factor))
          $debug << "Modified bounds to #{@bounds} to preserve aspect ratio<br>"
        end
      else
        $debug << "width, height, ignoreAspectRatio all specified;  using width and height as specified<br>"
      end
    elsif @output_width
      @output_height = (@output_width / @input_aspect_ratio).round
    else
      @output_width = (@output_height * @input_aspect_ratio).round
    end

    # Min width/height allowed by ffmpeg is 46x46
    @output_width = [@output_width, 46].max
    @output_height = [@output_height, 46].max

    # Ensure that the width and height are multiples of 2 for ffmpeg
    @output_width = ((@output_width - 1) / 2 + 1) * 2
    @output_height = ((@output_height - 1) / 2 + 1) * 2

    $debug << "output size: #{@output_width}px x #{@output_height}px<br>"

    frame_time = @cgi.params['frameTime'][0].to_f
    start_frame = @cgi.params['startFrame'][0]

    # Special case where we only pass in time and not full date as well
    start_time = @cgi.params['startTime'][0]
    end_time = @cgi.params['endTime'][0]
    # Our input times can be in the following formats:
    # hhmmss (for the above case), YYYYMMDDhhmmss, YYYYMMDDhhmm, YYYYMMDD, YYYYMM, YYYY
    bt = start_time || @cgi.params['bt'][0]
    et = end_time || @cgi.params['et'][0]

    dataset_frame_length = (@dataset_num_frames / @dataset_fps) / @dataset_num_frames

    # If both frameTime and startFrame are passed in, startFrame takes precedence.
    # Further precedence are for bt & et, which are more like human readable date strings.
    if bt and et and bt.length == et.length
      possible_input_formats = {
        14 => "%Y%m%d%H%M%S",
        12 => "%Y%m%d%H%M",
        8 => "%Y%m%d",
        6 => "%Y%m",
        4 => "%Y"
      }
      input_format = start_time ? "%H%M%S" : possible_input_formats[bt.length]

      if (start_time and start_time.length != 6) or not input_format
        raise "Invalid format for begin and end times"
      end

      # We need to figure out roughly what format our capture times are in. This will likely never be perfect but close enough.
      # TODO: Note that a capture time could be blank string or a string that says "NULL" but we currently ignore this.
      first_capture_time = @tm['capture-times'][0]
      date_delim = "-"
      is12Hour = false
      if first_capture_time.include?("/")
        date_delim = "/"
      end
      if first_capture_time.match(/ AM| PM/)
        is12Hour = true
      end

      capture_time_noformat = first_capture_time.gsub(/\/|-| |:|AM|PM/,'')

      if capture_time_noformat.length == 4
        capture_time_date_format = "%Y"
      elsif first_capture_time.split(date_delim)[0].length == 4
        if capture_time_noformat.length == 6
          capture_time_date_format = "%Y#{date_delim}%m"
        elsif capture_time_noformat.length >= 8
          capture_time_date_format = "%Y#{date_delim}%m#{date_delim}%d"
        end
      else
        capture_time_date_format = "%m#{date_delim}%d#{date_delim}%Y"
      end

      if capture_time_noformat.length > 8
        seconds_field = capture_time_noformat.length > 12 ? ":%S" : ""
        if is12Hour
          capture_time_time_format = " %I:%M#{seconds_field} %p"
        else
          capture_time_time_format = " %H:%M#{seconds_field}"
        end
      end

      capture_time_format = capture_time_date_format + capture_time_time_format

      if start_time
        input_format = capture_time_date_format + " " + input_format
        bt = first_capture_time.split(" ")[0] + " " + bt
        et = first_capture_time.split(" ")[0] + " " + et
      end

      begin
        start_capture_time = Time.strptime(bt, input_format).strftime(capture_time_format)
        end_capture_time = Time.strptime(et, input_format).strftime(capture_time_format)
      rescue
        raise "Invalid format for begin and end times"
      end

      tmp_start_frame = @tm['capture-times'].index(start_capture_time)
      tmp_end_frame = @tm['capture-times'].index(end_capture_time)

      # If we can't find exact match, find closest time match
      if start_time and (tmp_start_frame == nil or tmp_end_frame == nil)
        capture_times_as_epochs = @tm['capture-times'].map{|capture_time| Time.strptime(capture_time, capture_time_format).to_i}
        start_capture_time_as_epoch =  Time.strptime(start_capture_time, capture_time_format).to_i
        end_capture_time_as_epoch =  Time.strptime(end_capture_time, capture_time_format).to_i

        tmp_start_frame = capture_times_as_epochs.bsearch_index {|x| x >= start_capture_time_as_epoch}
        tmp_end_frame = capture_times_as_epochs.bsearch_index {|x| x >= end_capture_time_as_epoch}
      end

      if tmp_start_frame == nil or tmp_end_frame == nil
        start_frame = (frame_time / dataset_frame_length).floor
      else
        start_frame = tmp_start_frame
        frame_time = start_frame * dataset_frame_length
        @nframes = tmp_end_frame - tmp_start_frame + 1 if tmp_end_frame >= tmp_start_frame
      end
    elsif start_frame
      start_frame = start_frame.to_i
      frame_time = start_frame * dataset_frame_length
    else
      vlog(0, "About to compute start_frame #{frame_time} #{dataset_frame_length}" )
      start_frame = (frame_time / dataset_frame_length).floor
    end

    max_time = (@dataset_num_frames - 0.25).to_f / @dataset_fps
    @time = [0, [max_time, frame_time.to_f].min].max

    $debug << "Time to seek to: #{@time}<br>"

    @leader_seconds = 0
    if @r and @r.has_key?('leader')
      # FIXME: fractional leaders...
      @leader_seconds = @r['leader'].floor / @dataset_fps
      $debug << "Adding #{@leader_seconds} seconds of leader<br>"
      @time += @leader_seconds
    end

    @is_image = true
    @is_video = (@format == 'mp4' or @format == 'webm' or @format == 'zip') ? true : false

    @raw_formats = ['rgb24', 'gray8']

    if @raw_formats.include? @format or @format == 'gif' or @is_video
      @is_image = false
    end

    #
    # Fps for video output
    #
    #
    @video_output_fps = ""
    @desired_fps = @dataset_fps
    if @cgi.params.has_key? 'fps'
      @desired_fps = @cgi.params['fps'][0].to_f
      if @is_video
        raise "Output fps is required and must be greater than 0" unless @desired_fps
        @video_output_fps = "-r #{@desired_fps}"
      end
    end


    #
    # Take a screenshot of a page passed in as the root
    #
    #
    if @from_screenshot
      capture_frames_from_screenshot()
    else
      find_tile_for_non_screenshot()
    end

    if @legendHTML
      @tmpfile = "#{@tmp_dir}/#{Process.pid}.#{(Time.now.to_f)}-legend.json"
      File.open(@tmpfile, 'w') { |file| file.write(@legendContent.to_json) }
    else
      encode_frames()
    end
  end

  def delegate_thumbnail(thumbnail_worker_hostname)
    set_status('delegated')
    url = "https://#{thumbnail_worker_hostname}#{ENV['REQUEST_URI']}"
    url += "&workerepoch=#{(Time.now.to_f * 1000).round}"
    $stats['delegatedTo'] = url
    vlog(0, "CHECKPOINTTHUMBNAIL DELEGATION_START #{JSON.generate($stats)}")
    vlog(0, "Delegating thumbnail to #{thumbnail_worker_hostname}")

    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 3600 # wait 1 hour.  workers should abort before then
    response = http.get(URI(url))

    vlog(0, "Thumbnail returned from #{thumbnail_worker_hostname}, status code #{response.code}, body length #{response.body.size}")
    vlog(0, "CHECKPOINTTHUMBNAIL DELEGATION_FINISHED #{JSON.generate($stats)}")
    if response.code == "200"
      File.open(@tmpfile, 'w') { |file| file.write(response.body) }
    else
      exception_text = "Thumbnail delegation to #{thumbnail_worker_hostname} failed with status code #{response.code} and "
      if response.body.ascii_only?
        exception_text += "response body #{response.body}"
      else
        exception_text += "non-ascii response body of length #{response.body.length}"
      end
      raise exception_text
    end
  end

  def serve_thumbnail(cgi)
    @cgi = cgi
    @from_screenshot = false
    begin
      $debug << "<html><body>"
      $debug << "<pre>"
      $debug << JSON.pretty_generate(ENV.to_hash)
      $debug << "</pre><hr><pre>"
      $debug << JSON.pretty_generate(@cgi.params)
      $debug << "</pre>"
      $debug << "<hr>"

      if @cgi.params.has_key? 'test'
        test_html = File.open(File.dirname(File.realpath(__FILE__)) + '/test.html').read
        @cgi.out() {test_html}
        exit
      end

      @root = @cgi.params['root'][0] or raise "Missing 'root' param"
      @root = @root.sub(/\/$/, '')
      $debug << "root: #{@root}<br>"

      @format = @cgi.params['format'][0] || 'jpg'
      @output_as_json = @cgi.params['asJson'][0] == "true" ? true : false

      @tile_format = @cgi.params['tileFormat'][0] || 'webm'

      @nframes = @cgi.params['nframes'][0] || 1
      @nframes = @nframes.to_i

      @legendHTML = @cgi.params['legendHTML'][0] ? true : false
      if @legendHTML
        @nframes = 1
        @format = 'json'
      end

      recompute = @cgi.params.has_key? 'recompute'

      if ENV['QUERY_STRING'] and not $config['disable_cache']
        # Running in CGI mode;  enable cache
        cache_path = ENV['QUERY_STRING'].split("cachepath=")[1]
        cache_file = "#{@cache_dir}#{cache_path}"

        FileUtils.mkdir_p(File.dirname(cache_file))

        if @output_as_json
          # At this point, cache_file is the path to the json metadata that will be returned. We need to also have a cache path to the actual thumbnail itself

          # This is gross.
          # Apache already adds a slash to the encoded URL every 80 chars (see apache-serve.include). We need to undo this, remove the &asJson=true parameter and reapply the slashes.
          # We need this new path to use for saving the actual thumbnail data below.
          cache_path_substr = cache_path.match(/root=(.*)/)[0]
          cache_path_substr.gsub!("/", "")
          cache_path_substr.gsub!("026asJson=true", "")
          cache_path_substr = cache_path_substr.scan(/.{80}|.+/).join("/")
          cache_path2 = "/thumbnail/" + cache_path_substr

          # Actual thumbnail data (img, video, etc). We need to save this separately, since above we are saving a json file and here we are actually saving the thumbnail data itself.
          cache_file2 = "#{@cache_dir}#{cache_path2}"
          FileUtils.mkdir_p(File.dirname(cache_file2))
        end
      else
        # Running from commandline;  don't cache
        cache_file = nil
      end

      ['REMOTE_ADDR', 'HTTP_USER_AGENT', 'HTTP_REFERER'].each {|cgi_param|
        if ENV[cgi_param]
          $stats[cgi_param] = ENV[cgi_param]
        end
      }

      $begin_time = Time.now

      ###
      ### Return from cache, if already computed, or wait for cache if being computed in another process
      ###

      # Loop
      #   If thumbnail is in cache use it, done
      #   Create and attempt to (non-blocking) acquire lock on <cachepath>.compute
      #   Acquired? break from loop

      @from_screenshot = @cgi.params.has_key?('fromScreenshot')
      image_data = nil

      if cache_file
        compute_path = cache_file + '.compute'
        if @output_as_json
          compute_path2 = cache_file2 + '.compute'
        end
        compute_file = nil

        while true
          if File.exists?(cache_file) and not recompute
            vlog(0, "Found in cache.")
            $debug << "Found in cache."
            image_data = open(cache_file, 'rb') {|i| i.read}
            break
          end

          # If file isn't in cache and we've already locked the compute_file, exit loop and compute
          if compute_file
            break
          end

          compute_file = File.open(compute_path, 'w')
          if @output_as_json
            compute_file2 = File.open(compute_path2, 'w')
          end
          if not compute_file.flock(File::LOCK_NB | File::LOCK_EX)
            vlog(0, "Cannot lock compute lockfile; waiting for another process to finish computing")
            sleep(1)
            compute_file.close
            compute_file = nil
          end
        end
      end

      ###
      ### Compute if needed
      ###

      if not image_data
        vlog(0, "Not found in cache; computing")
        $request_url = ENV['REQUEST_SCHEME'] + '://' + ENV['HTTP_HOST'] + ENV['REQUEST_URI']
        vlog(0, "STARTTHUMBNAIL #{$request_url}")
        vlog(0, "CHECKPOINTTHUMBNAIL START #{JSON.generate($stats)}")
        @tmpfile = "#{@tmp_dir}/#{Process.pid}.#{(Time.now.to_f)}.#{@format}"

        if @from_screenshot
          thumbnail_worker_hostname = acquire_screenshot_semaphore()
        end

        if @from_screenshot and thumbnail_worker_hostname != 'localhost'
          # Writes to @tmpfile
          $status_url = "https://#{thumbnail_worker_hostname}/status?id=#{Process.pid}:#{$id}"
          delegate_thumbnail(thumbnail_worker_hostname)
        else
          $status_url = "#{File.dirname(ENV.to_hash['SCRIPT_URI'])}/status?id=#{Process.pid}:#{$id}"
          # Writes to @tmpfile
          compute_thumbnail()
        end

        image_data = open(@tmpfile, 'rb') {|i| i.read}
        $stats['sizeBytes'] = image_data.size
        $stats['totalTimeSecs'] = Time.now - $begin_time
        pt = Process.times
        $stats['cpuTime'] = pt.utime + pt.stime + pt.cutime + pt.cstime
        vlog(0, "ENDTHUMBNAIL #{$request_url} #{JSON.generate($stats)}")
        Stat.info("Completed thumbnail #{Process.pid}:#{$id} on #{ENV.to_hash['HTTP_HOST']} in #{'%.1f' % (Time.now - $begin_time)} seconds",
                  details: "<a href=\"#{$status_url}\">More info</a>")
        Stat.up("Last thumbnail successful")
        if cache_file
          final_file = cache_file
          if @output_as_json
            # JSON that contains the thumbnail capture bounds, url to the thumbnail, which host did the capturing, etc.
            # We save it using the original URL path, that includes the &asJson=true parameter.
            thumbnail_request_url = $request_url.gsub("&asJson=true", "")
            json_data = JSON.pretty_generate({"thumbnail-capture-bounds" => @aux_info['lat_lon_capture_bounds'], "thumbnail-url" => thumbnail_request_url, "thumbnail-worker-hostname" => thumbnail_worker_hostname})
            File.open(cache_file, 'w') { |file| file.write(json_data) }
            final_file = cache_file2
          end
          File.rename @tmpfile, final_file
          vlog(0, "Moved output file to cache: #{final_file}")
        else
          vlog(0, "Deleted output file");
          File.unlink @tmpfile
        end

        # Cleanup screenshot work
        if @tmpfile_screenshot_input_path
          FileUtils.rm_rf(@tmpfile_screenshot_input_path)
          if @format == 'zip'
            FileUtils.rm_rf(@tmpfile_zip_dir)
          end
        end

        if image_data and compute_file
          compute_file.close
          compute_file = nil
          FileUtils.rm_f(compute_path)
          if @output_as_json
            compute_file2.close
            compute_file2 = nil
            FileUtils.rm_f(compute_path2)
          end
        end

        #
        # Done
        #
      end

      $debug_mode = @cgi.params.has_key? '$debug'

      if $debug_mode
        $debug << "</body></html>"
        @cgi.out {$debug.join('')}
      else
        mime_types = {
          'gif' => 'image/gif',
          'jpg' => 'image/jpeg',
          'json' => 'application/json',
          'mp4' => 'video/mp4',
          'webm' => 'video/webm',
          'png' => 'image/png',
          'zip' => 'application/zip'
        }
        mime_type = mime_types[@format] || 'application/octet-stream'

        if @output_as_json
          @cgi.out('type' => 'application/json') {json_data}
        elsif (ENV['HTTP_RANGE'])
          size = File.size(cache_file)
          bytes = Rack::Utils.get_byte_ranges(ENV['HTTP_RANGE'], size)[0]
          offset = bytes.begin
          length = (bytes.end - bytes.begin) + 1
          @cgi.out('type' => mime_type, 'Accept-Ranges' => 'bytes', 'Content-Range' => "bytes #{bytes.begin}-#{bytes.end}/#{size}", 'Content-Length' => length, 'status' => "206") {image_data}
        else
          @cgi.out('type' => mime_type) {image_data}
        end
      end

    rescue SystemExit
      # ignore
    rescue Exception => e
      STDERR.puts e.backtrace.join("\n")
      $stats['FATALERROR'] = "#{e}\n#{e.backtrace.join("\n")}"
      vlog(0, "CHECKPOINTTHUMBNAIL FATALERROR #{JSON.generate($stats)}")
      $debug.insert 0, "400: Bad Request<br>"
      $debug.insert 2, "<pre>#{e}\n#{e.backtrace.join("\n")}</pre>"
      $debug.insert 3, "<hr>"
      @cgi.out('status' => 'BAD_REQUEST') {$debug.join('')}
      Stat.info("Thumbnail failed #{Process.pid}:#{$id} on #{ENV.to_hash['HTTP_HOST']} in #{'%.1f' %  (Time.now - $begin_time)} seconds",
                details: "<a href=\"#{$status_url}\">More info</a>")
      Stat.up("Last thumbnail failed")
    end
  end
end

ThumbnailGenerator.new.serve_thumbnail(cgi)

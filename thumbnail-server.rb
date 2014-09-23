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
load File.dirname(File.realpath(__FILE__)) + '/mercator.rb'
load File.dirname(File.realpath(__FILE__)) + '/point.rb'
load File.dirname(File.realpath(__FILE__)) + '/bounds.rb'

cache_dir = File.dirname(File.realpath(__FILE__)) + '/cache'

filter_dir = File.dirname(File.realpath(__FILE__)) + '/filters'

ffmpeg_path = nil

ffmpeg_candidates = ['/usr/local/bin/ffmpeg', '/usr/bin/ffmpeg', '/opt/local/bin/ffmpeg', File.dirname(File.realpath(__FILE__)) + '/../tilestacktool/ffmpeg/osx/ffmpeg']
ffmpeg_candidates.each do |candidate|
  if File.exists? candidate
    ffmpeg_path = candidate
    break
  end
end

ffmpeg_path or raise "Can't find ffmpeg in #{ffmpeg_candidates}"

cgi = CGI.new

debug = []

def parse_bounds(cgi, key)
  if not cgi.params.has_key?(key)
    return false
  end
  bounds = cgi.params[key][-1].split(',').map(&:to_f)
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

  root = cgi.params['root'][0] or raise "Missing 'root' param"
  root = root.sub(/\/$/, '')
  debug << "root: #{root}<br>"

  format = cgi.params['format'][0] || 'jpg'

  tile_format = cgi.params['tileFormat'][0] || 'webm'

  nframes = cgi.params['nframes'][0] || 1

  recompute = cgi.params.has_key? 'recompute'

  if ENV['QUERY_STRING']
    # Running in CGI mode;  enable cache
    hash = Digest::SHA512.hexdigest(ENV['QUERY_STRING'])
    cache_file = "#{cache_dir}/#{hash[0...3]}/#{hash}.#{format}"
  else
    # Running from commandline;  don't cache
    cache_file = nil
  end

  if cache_file and File.exists?(cache_file) and not recompute
    STDERR.puts "Found in cache."
    debug << "Found in cache."
    image_data = open(cache_file) {|i| i.read}
  else
    STDERR.puts "Not found in cache; computing"
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

    #
    # Parse bounds
    #

    timemachine_width = r['width']
    timemachine_height = r['height']
    debug << "timemachine dims: #{timemachine_width} x #{timemachine_height}<br>"

    boundsNWSE = parse_bounds(cgi, 'boundsNWSE')
    boundsLTRB = parse_bounds(cgi, 'boundsLTRB')

    boundsNWSE and boundsLTRB and raise "Exactly one of boundsNWSE and boundsLTRB must be specified, but both were"
    !boundsNWSE and !boundsLTRB and raise "Exactly one of boundsNWSE and boundsLTRB must be specified, but neither was"

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
        aspect_factor = Math.sqrt(output_aspect_ratio / input_aspect_ratio)
        bounds = Bounds.with_center(bounds.center,
                                    Point.new(bounds.size.x * aspect_factor, bounds.size.y / aspect_factor))
        debug << "Modified bounds to #{bounds} to preserve aspect ratio<br>"
      else
        debug << "width, height, ignoreAspectRatio all specified;  using width and height as specified<br>"
      end
    elsif output_width
      output_height = (output_width / input_aspect_ratio).round
    else
      output_width = (output_height * input_aspect_ratio).round
    end

    debug << "output size: #{output_width}px x #{output_height}px<br>"

    #
    # Search for tile
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

    #
    # Construct ffmpeg invocation
    #

    # frameTime defaults to 0
    time = (cgi.params['frameTime'][0] || 0).to_f
    # Reduce time by 99% of the size of a frame
    time -= (1.0 / r['fps'].to_f) * 0.99
    if r.has_key?('leader')
      # FIXME: fractional leaders...
      leader_seconds = r['leader'].floor() / r['fps'].to_f
      debug << "Adding #{leader_seconds} seconds of leader<br>"
      time += leader_seconds
    end

    if cache_file
      tmpfile = "#{cache_file}.tmp-#{Process.pid}.#{format}"
    else
      tmpfile = "/tmp/thumbnail-server-#{Process.pid}.#{format}"
    end

    FileUtils.mkdir_p(File.dirname(tmpfile))

    # ffmpeg ignores negative crop bounds.  So if we have a negative crop bound,
    # pad the upper left and offset the crop
    pad_size = video_size
    pad_tl = Point.new([0, -(crop.min.x.floor)].max,
                       [0, -(crop.min.y.floor)].max)
    crop = crop + pad_tl
    pad_size = pad_size + pad_tl

    if time < 0
      time = 0
    end

    cmd = "#{ffmpeg_path} -y -ss #{time} -i #{tile_url} -vf 'pad=#{pad_size.x}:#{pad_size.y}:#{pad_tl.x}:#{pad_tl.y},crop=#{crop.size.x}:#{crop.size.y}:#{crop.min.x}:#{crop.min.y},scale=#{output_width}:#{output_height}' -vframes #{nframes}"

    raw_formats = ['rgb24', 'gray8']
    is_image = true

    if raw_formats.include? format
      cmd += " -f rawvideo -pix_fmt #{format}"
      is_image = false
    end

    if format == 'jpg'
      # compression quality;  lower is higher quality
      #cmd += ' -q:v 2'
      cmd += ' -qscale 2' # older syntax
    end

    if format == 'gif'
      is_image = false
    end

    if is_image && nframes != 1
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
      delay = cgi.params['delay'][0] ||	20
      # pipe:1 makes ffmpeg output to stdout
      cmd += " -f image2pipe -vcodec ppm - | /usr/bin/convert -delay #{delay} -loop 0 - "
      format = 'gif'
    end



    cmd += " '#{tmpfile}'"

    debug << "Running: '#{cmd}'<br>"
    output = `#{cmd} 2>&1`;
    if not $?.success?
      debug << "ffmpeg failed with output:<br>"
      debug << "<pre>#{output}</pre>"
      raise "Error executing '#{cmd}'"
    end

    image_data = open(tmpfile) {|i| i.read}

    if cache_file
      File.rename tmpfile, cache_file
    else
      File.unlink tmpfile
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
    exit 0
  else
    mime_types = {
      'jpg' => 'image/jpeg',
      'png' => 'image/png',
      'json' => 'application/json',
      'gif' => 'image/gif'
    }
    mime_type = mime_types[format] || 'application/octet-stream'
    cgi.out('type' => mime_type, 'Access-Control-Allow-Origin' => '*') {image_data}
  end

rescue Exception => e
  debug.insert 0, "400: Bad Request<br>"
  debug.insert 2, "<pre>#{e}\n#{e.backtrace.join("\n")}</pre>"
  debug.insert 3, "<hr>"
  cgi.out('status' => 'BAD_REQUEST', 'Access-Control-Allow-Origin' => '*') {debug.join('')}
end

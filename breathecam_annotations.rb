# Breathecam overlay annotations rendered via ffmpeg drawtext.
#
# Single source of truth for the time-of-frame (upper-left) and camera-name
# (upper-right) overlays that breathecam.org's UI paints in minimalUI mode.
# The from-screenshot pipeline currently gets these "for free" because Chrome
# renders the breathecam.org JS UI before we screenshot; the from-export
# pipeline goes straight from raw tile bytes and so doesn't have them.
# Calling .filter_fragments from encode_frames yields parity.
#
# Camera display names come from https://breathecam.org/cameras.json (cached
# on disk, refreshed every 24h). Falls back to a titlecased shortname if the
# id is missing from the map.
#
# All times are assumed to be in America/New_York (every breathecam camera
# today). When that ever changes, this is where to teach about timezones.

require 'json'
require 'net/http'
require 'fileutils'
require 'uri'

module BreathecamAnnotations
  CAMERAS_URL    = 'https://breathecam.org/cameras.json'
  CACHE_PATH     = File.join(File.dirname(__FILE__), 'tmp', 'breathecam-cameras.json')
  CACHE_TTL_SEC  = 24 * 60 * 60
  FETCH_TIMEOUT  = 5
  FONT           = './fonts/DroidSans.ttf'
  # Common drawtext styling applied to both the time and camera-name overlays.
  # ft_load_flags=no_hinting disables freetype's grid-snapping, which at small
  # sizes produces visibly pixelated/stairstep glyph edges; without hinting
  # libfreetype outputs cleaner sub-pixel antialiasing.
  STYLE          = 'fontcolor=white:borderw=1:bordercolor=black:' \
                   'ft_load_flags=no_hinting'

  @@names_loaded = false
  @@names        = {}

  def self.camera_display_name(shortname)
    load_camera_names
    @@names[shortname.to_s] || titlecase(shortname)
  end

  # Returns a string of comma-prefixed ffmpeg drawtext filter snippets to
  # append to the encode_frames label chain, e.g.
  #   ",drawtext@bc_time=...:text='2026-05-14 14\\:00\\:01',
  #     sendcmd=f='...',drawtext@bc_name=...:text='Clairton Coke Works'"
  # As a side effect, writes a sendcmd-commands file for the per-frame
  # timestamp updates at <tmpfile_prefix>.breathecam_time.cmd.
  # Returns "" if there is no data to annotate.
  def self.filter_fragments(capture_times:, frame_indices:, camera_shortname:,
                            output_width:, output_height:, nframes:, desired_fps:,
                            tmpfile_prefix:)
    fragments  = []
    fontsize   = [(output_height * 0.04).round, 12].max

    selected = frame_indices.first(nframes).map { |i| capture_times[i].to_s }
    if !selected.empty? && desired_fps && desired_fps > 0
      texts = selected.map { |t| escape_drawtext(t) }
      first = texts[0]
      time_filter = "drawtext@bc_time=fontfile=#{FONT}:fontsize=#{fontsize}:" \
                    "#{STYLE}:x=8:y=6:text='#{first}'"
      if texts.length > 1
        sendcmd_path = "#{tmpfile_prefix}.breathecam_time.cmd"
        frame_dur = 1.0 / desired_fps
        cmds = []
        texts.each_with_index do |t, i|
          next if i == 0
          cmds << "#{format('%.6f', i * frame_dur)} drawtext@bc_time reinit 'text=#{t}'"
        end
        File.write(sendcmd_path, cmds.join(';') + ';')
        time_filter += ",sendcmd=f='#{sendcmd_path}'"
      end
      fragments << time_filter
    end

    name = camera_display_name(camera_shortname)
    if name && !name.empty?
      safe_name = escape_drawtext(name)
      fragments << "drawtext@bc_name=fontfile=#{FONT}:fontsize=#{fontsize}:" \
                   "#{STYLE}:x=w-tw-8:y=6:text='#{safe_name}'"
    end

    fragments.empty? ? '' : ',' + fragments.join(',')
  end

  # ---- internals ----

  def self.load_camera_names
    return if @@names_loaded

    cached     = read_cache
    cache_stat = File.exist?(CACHE_PATH) ? File.mtime(CACHE_PATH) : nil
    cache_stale = cache_stat.nil? || (Time.now - cache_stat) > CACHE_TTL_SEC

    if cache_stale
      begin
        fresh = fetch_remote
        write_cache(fresh)
        cached = fresh
      rescue => e
        # If we have stale cache, prefer it over nothing; otherwise we'll fall
        # back to titlecasing inside camera_display_name.
        warn "BreathecamAnnotations: cameras.json fetch failed (#{e.class}: #{e.message})"
      end
    end

    @@names        = build_name_map(cached || {})
    @@names_loaded = true
  end

  def self.read_cache
    return nil unless File.exist?(CACHE_PATH)
    JSON.parse(File.read(CACHE_PATH))
  rescue
    nil
  end

  def self.write_cache(data)
    FileUtils.mkdir_p(File.dirname(CACHE_PATH))
    tmp = "#{CACHE_PATH}.#{Process.pid}.tmp"
    File.write(tmp, JSON.generate(data))
    File.rename(tmp, CACHE_PATH)
  end

  def self.fetch_remote
    uri = URI(CAMERAS_URL)
    Net::HTTP.start(uri.host, uri.port,
                    use_ssl: uri.scheme == 'https',
                    open_timeout: FETCH_TIMEOUT,
                    read_timeout: FETCH_TIMEOUT) do |http|
      resp = http.get(uri.request_uri)
      raise "HTTP #{resp.code}" unless resp.is_a?(Net::HTTPSuccess)
      JSON.parse(resp.body)
    end
  end

  def self.build_name_map(data)
    map = {}
    (data['locations'] || []).each do |loc|
      map[loc['id']] = loc['name'] if loc['id'] && loc['name']
    end
    map
  end

  def self.titlecase(s)
    s.to_s.gsub(/(?<=[A-Za-z])(\d+)/, ' \1').split(/[\s_\-]+/).map(&:capitalize).join(' ')
  end

  # ffmpeg drawtext: escape colons (they delimit options) and drop quotes
  # (text='...' can't carry embedded quotes safely).
  def self.escape_drawtext(s)
    s.to_s.gsub(/[':"]/) { |c| c == ':' ? '\\:' : '' }
  end
end

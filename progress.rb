#!/usr/bin/env ruby

# Per-request progress endpoint. Reads <cache_file>.progress (written
# atomically by thumbnail-server.rb) and returns it as JSON. If the
# cached output already exists, returns {state: "done"}. If the local
# progress says state="delegated", reverse-proxies to the named host's
# /progress?<same-query> so the client always sees the rendering
# machine's live counters.
#
# Query string protocol: same shape as thumbnail-server.rb expects.
# After Apache rewriting we get `cachepath=<encoded-path>` (see
# apache-serve.include); we look up <cache_dir><cachepath>.

require 'json'
require 'net/http'
require 'uri'

CACHE_DIR = File.dirname(File.dirname(File.realpath(__FILE__))) + '/cache'
REMOTE_TIMEOUT_S = 5
MAX_PROXY_HOPS = 2

def emit(payload, status: '200 OK')
  body = payload.is_a?(String) ? payload : JSON.generate(payload)
  puts "Status: #{status}"
  puts 'Content-Type: application/json'
  puts 'Cache-Control: no-store'
  puts 'Access-Control-Allow-Origin: *'
  puts ''
  puts body
end

qs = ENV['QUERY_STRING'] || ''
cache_path = qs.split('cachepath=', 2)[1]

if cache_path.nil? || cache_path.empty?
  emit({state: 'error', message: 'missing cachepath'}, status: '400 Bad Request')
  exit
end

# Apache's rewrite chain replaces '.' with 02E etc., so a real cachepath
# cannot contain '..'. Anything with '..' is a traversal attempt.
if cache_path.include?('..')
  emit({state: 'error', message: 'invalid cachepath'}, status: '400 Bad Request')
  exit
end

cache_file    = "#{CACHE_DIR}#{cache_path}"
progress_path = "#{cache_file}.progress"

# Cache file exists → compute finished.
if File.exists?(cache_file)
  emit({state: 'done'})
  exit
end

unless File.exists?(progress_path)
  # Tiny race: cache_file may have appeared between the check above and now,
  # e.g. the worker finished writing right after we looked. Recheck before
  # giving up to "unknown".
  if File.exists?(cache_file)
    emit({state: 'done'})
    exit
  end
  emit({state: 'unknown'})
  exit
end

data = begin
  JSON.parse(File.read(progress_path))
rescue Errno::ENOENT
  # Raced with the writer's rename or with clear_progress on completion.
  if File.exists?(cache_file)
    emit({state: 'done'})
    exit
  end
  emit({state: 'unknown'})
  exit
rescue JSON::ParserError
  emit({state: 'unknown', message: 'progress file unreadable'})
  exit
end

# Cross-machine reverse-proxy. Bounded with an X-Progress-Hops header so a
# misconfiguration cannot infinite-loop two hosts off of each other.
delegated_to = data['delegated_to']
hops = (ENV['HTTP_X_PROGRESS_HOPS'] || '0').to_i
if delegated_to && hops < MAX_PROXY_HOPS
  remote_url = "https://#{delegated_to}/progress?#{qs}"
  begin
    uri = URI.parse(remote_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = REMOTE_TIMEOUT_S
    http.read_timeout = REMOTE_TIMEOUT_S
    req = Net::HTTP::Get.new(uri.request_uri)
    req['X-Progress-Hops'] = (hops + 1).to_s
    resp = http.request(req)
    if resp.code == '200'
      emit(resp.body)
      exit
    end
    data['remote_status_code'] = resp.code
  rescue => e
    data['remote_error'] = e.message
  end
end

emit(data)

#!/usr/bin/env ruby

# Per-request progress endpoint. Reads <cache_file>.progress (written
# atomically by thumbnail-server.rb) and returns it as JSON. If the cached
# output already exists, returns {state: "done"}.
#
# The cache (and thus the .progress file) is shared across all workers via NFS,
# so any worker's progress.rb can answer a poll for any request — there is no
# cross-host relay.
#
# Query string protocol: same shape as thumbnail-server.rb expects.
# After Apache rewriting we get `cachepath=<encoded-path>` (see
# apache-serve.include); we look up <cache_dir><cachepath>.

require 'json'

CACHE_DIR = File.dirname(File.dirname(File.realpath(__FILE__))) + '/cache'

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
if File.exist?(cache_file)
  emit({state: 'done'})
  exit
end

unless File.exist?(progress_path)
  # Tiny race: cache_file may have appeared between the check above and now,
  # e.g. the worker finished writing right after we looked. Recheck before
  # giving up to "unknown".
  if File.exist?(cache_file)
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
  if File.exist?(cache_file)
    emit({state: 'done'})
    exit
  end
  emit({state: 'unknown'})
  exit
rescue JSON::ParserError
  emit({state: 'unknown', message: 'progress file unreadable'})
  exit
end

emit(data)

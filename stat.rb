class StatInstance
  def initialize(use_staging_server=false)
    $freed = 9999
    if use_staging_server
      @server_hostname = 'stat-staging.createlab.org'
    else
      @server_hostname = 'stat.createlab.org'
    end
    @hostname = nil
    @service = nil
  end
  
  def get_datetime
    return Time.now.iso8601
  end
  
  def get_hostname
    if not @hostname
      @hostname = `hostname`.trim
    end
    return @hostname
  end
  
  def set_service(service)
    @service = service
  end
  
  def set_hostname(hostname)
    @hostname = hostname
  end
  
  # Possible levels include 'up', 'down', 'info', 'debug', 'warning', critical'
  def log(service, level, summary, details: nil, host: nil, payload: {}, valid_for_secs: nil)
    service ||= @service
    if not service
      raise 'log: service must be passed, or set previously with set_service'
    end
    host ||= get_hostname
    post_body = {
      'service' => service,
      'datetime' => get_datetime(),
      'host' => host,
      'level' => level,
      'summary' => summary,
      'details' => details,
      'payload' => payload,
      'valid_for_secs' => valid_for_secs
    }
    
    url = "https://#{@server_hostname}/api/log"

    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    vlog(0, "url is #{url} host #{uri.host} port #{uri.port}")
    http.use_ssl = true
    http.read_timeout = 20

    request = Net::HTTP::Post.new(url)
    request.content_type = "application/json"    
    request.body = post_body.to_json

    vlog(0, "request.body #{request.body}")

    begin
      response = http.request(request)

      if response.code != '200'
        $stderr.puts "POST to #{url} failed with status code #{response.code} and response #{response.body}"
        return
      end
    rescue StandardError => error
      $stderr.puts "POST to #{url} failed: #{error}"
    end
  end
  
  def info(summary, details: nil, payload: {}, host: nil)
    log(nil, 'info', summary, details: details, payload: payload, host: host)
  end

  def debug(summary, details=nil, payload={}, host=nil)
    log(nil, 'debug', summary, details: details, payload: payload, host: host)
  end
  
  def warning(summary, details=nil, payload={}, host=nil)
    log(nil, 'warning', summary, details: details, payload: payload, host: host)
  end

  def critical(summary, details=nil, payload={}, host=nil)
    log(nil, 'critical', summary, details: details, payload: payload, host: host)
  end
  
  def up(summary, details=nil, payload={}, valid_for_secs=nil, host=nil)
    log(nil, 'up', summary, details: details, payload: payload, valid_for_secs: valid_for_secs, host: host)
  end

  def down(summary, details=nil, payload={}, valid_for_secs=nil, host=nil)
    log(nil, 'down', summary, details: details, payload: payload, valid_for_secs: valid_for_secs, host: host)
  end
end

Stat = StatInstance.new()

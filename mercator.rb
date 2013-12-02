class MercatorProjection 
  def initialize(boundsNWSE, width, height)
    @north = boundsNWSE['north'] or raise "boundsNWSE missing north"
    @west  = boundsNWSE['west']  or raise "boundsNWSE missing west"
    @south = boundsNWSE['south'] or raise "boundsNWSE missing south"
    @east  = boundsNWSE['east']  or raise "boundsNWSE missing east"
    @width = width
    @height = height
  end
  
  def rawProjectLat(lat)
    Math.log((1+Math.sin(lat*Math::PI/180))/Math.cos(lat*Math::PI/180))
  end
  
  def rawUnprojectLat(y)
    (2 * Math.atan(Math.exp(y)) - Math::PI / 2) * 180 / Math::PI
  end
  
  def interpolate(x, fromLow, fromHigh, toLow, toHigh)
    (x - fromLow) / (fromHigh - fromLow) * (toHigh - toLow) + toLow;
  end
  
  def latlngToPoint(latlng)
    x = interpolate(latlng['lng'], @west, @east, 0, @width);
    y = interpolate(rawProjectLat(latlng['lat']), rawProjectLat(@north), rawProjectLat(@south), 0, @height);
    {'x' => x, 'y' => y}
  end
  
  def pointToLatlng(point)
    lng = interpolate(point['x'], 0, @width, @west, @east);
    lat = rawUnprojectLat(interpolate(point['y'], 0, @height, rawProjectLat(@north), rawProjectLat(@south)))
    {'lat' => lat, 'lng' => lng}
  end
end    

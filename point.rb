class Point
  attr_accessor :x, :y
  
  def initialize(x, y)
    @x = x
    @y = y
  end

  def to_s
    "#{x},#{y}"
  end

  def /(rhs)
    if rhs.is_a? Point
      Point.new(x / rhs.x, y / rhs.y)
    else
      Point.new(x / rhs, y / rhs)
    end
  end

  def *(rhs)
    if rhs.is_a? Point
      Point.new(x * rhs.x, y * rhs.y)
    else
      Point.new(x * rhs, y * rhs)
    end
  end

  def +(rhs)
    if rhs.is_a? Point
      Point.new(x + rhs.x, y + rhs.y)
    else
      Point.new(x + rhs, y + rhs)
    end
  end

  def -(rhs)
    if rhs.is_a? Point
      Point.new(x - rhs.x, y - rhs.y)
    else
      Point.new(x - rhs, y - rhs)
    end
  end

  def floor
    Point.new(x.floor, y.floor)
  end
end

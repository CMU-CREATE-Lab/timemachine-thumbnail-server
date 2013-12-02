class Bounds
  attr_accessor :min, :max

  def initialize(min, max)
    @min = min
    @max = max
  end

  def self.with_center(center, size)
    new center - (size * 0.5), center + (size * 0.5)
  end

  def contains(rhs)
    min.x <= rhs.min.x &&
      min.y <= rhs.min.y &&
      rhs.max.x <= max.x &&
      rhs.max.y <= max.y
  end

  def /(rhs)
    Bounds.new(min / rhs, max / rhs)
  end

  def -(rhs)
    Bounds.new(min - rhs, max - rhs)
  end

  def floor
    Bounds.new(min.floor, max.floor)
  end

  def size
    max - min
  end

  def to_s
    "(#{min}) - (#{max})"
  end

  def center
    (min + max) * 0.5
  end
end

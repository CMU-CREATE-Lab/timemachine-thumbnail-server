class FlockSemaphore
  @lockedFile

  def initialize(dir)
    @dir = dir
  end

  def captureNonblock
    if @lockedFile
      raise "captureNonblock:  already captured"
    end
    Dir.glob(@dir + '/*').sort.each {|candidate|
      f = File.open(candidate, 'r')
      if f.flock(File::LOCK_NB|File::LOCK_EX)
        @lockedFile = f
        return candidate
      end
      f.close()
    }
    return false
  end

  def release
    if @lockedFile
      @lockedFile.close()
      @lockedFile = nil
    end
  end
end

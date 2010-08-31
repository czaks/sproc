# SProc - A simple signal processing package for Ruby
# Copyright (c) 2010 Marcin Łabanowski
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

class SProc
  attr_accessor :files
  
  def initialize()
    self.files = {}
  end
  
  def add(name, filename)
    newobj = self.dup
    newobj.add!(name, filename)
  end
    
  def add!(name, filename)
    self.files[name] = SProc::IO.new(filename, "r")
    self
  end
  
  def self.add(name, filename)
    self.new.add!(name, filename)
  end
  
  def process(outfile="/dev/stdout", &block)
    output = SProc::IO.new(outfile, "w")
    time = 0
    while true
      out = yield self.files, time
      break if out == :eof
      output << out
      time+=1
    end
    
    self.class.add(outfile)
  end
  
  class IO
    attr_accessor :fp, :mode
    attr_accessor :channels, :samplerate, :bps, :samplecount, :startbyte
    attr_accessor :position, :cursample
    attr_accessor :buffer
    
    MIN=-32768
    MAX=32767
    
    def initialize(filename, mode="r")
      self.mode = mode
      if filename.class <= ::IO
        self.fp = filename
      elsif filename.class == String
        self.fp = File.open(filename, mode)
      end
      
      case mode
      when "r"
        #Determine file type. Only WAV files supported currently
        fp.read(4) == "RIFF" or raise "Not a RIFF file"
        fp.read(4) #ChunkSize; none of the interest for us
        fp.read(4) == "WAVE" or raise "Not a WAVE file"
        
        loop do
          case fp.read(4)
          when "fmt "
            #Subchunk 1 - "fmt "
            #fp.read(4) == "fmt " or raise "Subchunk is not fmt "
            pad = 16 - fp.read(4).unpack("V").pop #additional info we don't support?
            
            fp.read(2) == [1].pack("v") or raise "Not a WAVE-PCM file"
            self.channels = fp.read(2).unpack("v").pop
            self.samplerate = fp.read(4).unpack("V").pop
            fp.read(4) # byterate == SampleRate * NumChannels * BitsPerSample/8
            fp.read(2) # blockalign == NumChannels * BitsPerSample/8
            self.bps = fp.read(2).unpack("v").pop
          
            fp.read(pad) if pad > 0
          when "data"
            self.channels or raise "\"fmt \" chunk not appeared before the data chunk"
            #Subchunk 2 - "data"
            #fp.read(4) == "data" or raise "Subchunk is not data"
            self.samplecount = fp.read(4).unpack("V").pop / (self.channels * (self.bps/8))
            begin
              self.startbyte = fp.tell
            rescue Errno::ESPIPE
              self.startbyte = nil #non-seekable
            end
            self.position = 0
            break #File is now ready for reading
          else
            subchunksize = fp.read(4).unpack("V").pop
            fp.read(subchunksize)
          end
        end
      when "w"
        begin
          self.startbyte = fp.tell
          self.buffer = fp
        rescue Errno::ESPIPE
          self.startbyte = nil #non-seekable
          self.buffer = ""
        end
        
        self.channels, self.samplerate, self.bps = 2, 44100, 16
        
        self.buffer << "RIFF" << [0].pack("V") << "WAVE"
        self.buffer << "fmt " << 
          [16,1,channels,samplerate,samplerate*channels*bps/8].pack("VvvVV") <<
          [channels*bps/8,bps].pack("vv")
          
        self.buffer << "data" << [0].pack("V")
        
        self.startbyte = fp.tell if self.startbyte
        self.position = 0
      end
    end
    
    def getnext(numchunks=1)
      self.mode == "r" or raise "Resource not opened for reading"
      
      chunks = []
      numchunks.times do |v|
        if position >= samplecount
          chunks << :eof
          break
        end
        chanvalues = []
        self.channels.times do |i|
          chanvalues << if self.bps == 8
            sample = fp.read(1).unpack("C").pop
            (sample - 128) * 256
          elsif self.bps == 16
            fp.read(2).unpack("s").pop # TODO: little endian dependent?
          else
            raise "Unknown bits per sample counter"
          end
        end
        self.cursample = chanvalues
        chunks << chanvalues
        self.position += 1
      end
      chunks
    end
    
    def each(&block)
      loop do
        n = getnext.pop
        break if n == :eof
        yield getnext.pop
      end
    end    
    include Enumerable
    
    def [](sample)
      if self.startbyte
        return :eof if sample >= samplecount
        oldpos = fp.tell
        newpos = self.startbyte + sample * channels * bps / 8
        oldsample = self.position
        
        fp.pos = newpos
        self.position = sample
        
        out = getnext.pop
        
        fp.pos = oldpos
        self.position = oldsample
        
        out
      else
        if sample == self.position
          cursample
        elsif sample > self.position
          getnext(sample - self.position)
          cursample
        else
          raise "Can't rewind this stream"
        end
      end
    end
    
    def <<(sample) #append
      mode == "w" or raise "File is not opened for writing"
      
      sample = sample[0,channels]
      while sample.size < channels
        sample << sample[0]
      end
      
      sample.each do |i|
        i = -32768 if i < -32768
        i =  32767 if i >  32767
        buffer << [i].pack("s") # TODO: Little endian dependent?
      end
      self.position += 1
    end
    
    def close
      if mode == "w" # Fix the header size fields
        if self.startbyte
          fp.pos = 4
          fp << [36 + position * channels * bps/8].pack("V")
          fp.pos = 40
          fp << [position * channels * bps/8].pack("V")
        else
          self.buffer[4,4] = [36 + position * channels * bps/8].pack("V")
          self.buffer[40,4] = [position * channels * bps/8].pack("V")
          #Flush buffer
          fp << buffer
        end
      end
      
      fp.close
    end
  end
end

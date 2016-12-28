module Numo

  def gnuplot(&block)
    if block
      Gnuplot.default.instance_eval(&block)
    else
      Gnuplot.default
    end
  end
  module_function :gnuplot

  def noteplot(&block)
    Gnuplot::NotePlot.new(&block)
  end
  module_function :noteplot

class Gnuplot

  VERSION = "0.1.6"
  POOL = []
  DATA_FORMAT = "%.7g"

  class GnuplotError < StandardError; end

  def self.default
    POOL[0] ||= self.new
  end

  class NotePlot
    def initialize(&block)
      if block.nil?
        raise ArgumentError,"block is needed"
      end
      @block = block
    end

    def to_iruby
      require 'tempfile'
      tempfile_svg = Tempfile.open('plot')
      # output SVG to tmpfile
      gp = Gnuplot.default
      gp.reset
      gp.set terminal:'svg', output:tempfile_svg.path
      gp.instance_eval(&@block)
      gp.unset 'output'
      svg = File.read(tempfile_svg.path)
      tempfile_svg.close
      ["image/svg+xml",svg]
    end
  end

  def initialize(gnuplot_command="gnuplot")
    @history = []
    @debug = false
    r0,@iow = IO.pipe
    @ior,w2 = IO.pipe
    IO.popen(gnuplot_command,:in=>r0,:err=>w2)
    r0.close
    w2.close
    @gnuplot_version = send_cmd("print GPVAL_VERSION")[0].chomp
    if /\.(\w+)$/ =~ (filename = ENV['NUMO_GNUPLOT_OUTPUT'])
      ext = $1
      ext = KNOWN_EXT[ext] || ext
      opts = ENV['NUMO_GNUPLOT_OPTION'] || ''
      set terminal:[ext,opts]
      set output:filename
    end
  end

  attr_reader :history
  attr_reader :last_message
  attr_reader :gnuplot_version

  # draw 2D functions and data.
  def plot(*args)
    _plot_splot("plot",args)
    nil
  end

  # draws 2D projections of 3D surfaces and data.
  def splot(*args)
    _plot_splot("splot",args)
    nil
  end

  def _plot_splot(cmd,args)
    contents = parse_plot_args(cmd,args)
    r = contents.shift.map{|x|"[#{x.begin}:#{x.end}] "}.join
    c = contents.map{|x| x.cmd_str}.join(",")
    d = contents.map{|x| x.data_str}.join
    run "#{cmd} #{r}#{c}", d
    nil
  end
  private :_plot_splot

  # replot is not recommended, use refresh
  def replot
    run "replot\n#{@last_data}"
    nil
  end

  # The `set` command is used to set _lots_ of options.
  def set(*args)
    _set_unset("set",args)
    nil
  end

  # The `unset` command is used to return to their default state.
  def unset(*args)
    _set_unset("unset",args)
    nil
  end

  def _set_unset(cmd,args)
    args.each do |a|
      case a
      when Hash
        a.each do |k,v|
          run "#{cmd} #{OptArg.parse_kv(k,v)}"
        end
      else
        run "#{cmd} #{a}"
      end
    end
    nil
  end
  private :_set_unset

  # The `help` command displays built-in help.
  def help(s=nil)
    puts send_cmd "help #{s}\n\n"
  end

  # The `show` command shows their settings.
  def show(x)
    puts send_cmd "show #{x}"
  end

  #  The `reset` command causes all graph-related options that can be
  #  set with the `set` command to take on their default values.
  def reset(x=nil)
    run "reset #{x}"
    nil
  end

  # The `pause` command used to wait for events on window.
  # Carriage return entry (-1 is given for argument) and
  # text display option is disabled.
  #    pause 10
  #    pause 'mouse'
  #    pause mouse:%w[keypress button1 button2 button3 close any]
  def pause(*args)
    send_cmd("pause #{OptArg.parse(*args)}").join.chomp
    nil
  end

  # The `load` command executes each line of the specified input file.
  def load(filename)
    send_cmd "load '#{filename}'"
    nil
  end

  alias kernel_raise :raise

  # The `raise` command raises plot window(s)
  def raise_plot(plot_window_nb=nil)
    send_cmd "raise #{plot_window_nb}"
    nil
  end
  alias raise :raise_plot

  # The `lower` command lowers plot window(s)
  def lower_plot(plot_window_nb=nil)
    send_cmd "lower #{plot_window_nb}"
    nil
  end
  alias lower :lower_plot

  # The `clear` command erases the current screen or output device as specified
  # by `set output`. This usually generates a formfeed on hardcopy devices.
  def clear
    send_cmd "clear"
    nil
  end

  # The `exit` and `quit` commands will exit `gnuplot`.
  def exit
    send_cmd "exit"
    nil
  end

  # The `exit` and `quit` commands will exit `gnuplot`.
  def quit
    send_cmd "quit"
    nil
  end

  # The `refresh` reformats and redraws the current plot using the
  # data already read in.
  def refresh
    send_cmd "refresh"
    nil
  end

  # `var` returns Gnuplot variable (not Gnuplot command)
  def var(name)
    res = send_cmd("print #{name}").join("").chomp
    if /undefined variable:/ =~ res
      kernel_raise GnuplotError,res.strip
    end
    res
  end

  KNOWN_EXT = {"ps"=>"postscript","jpg"=>"jpeg"}

  # output current plot to file with terminal setting from extension
  # (not Gnuplot command)
  def output(filename,*opts)
    if /\.(\w+)$/ =~ filename
      ext = $1
      ext = KNOWN_EXT[ext]||ext
      set terminal:[ext,*opts], output:filename
      refresh
      unset :terminal, :output
    else
      kernel_raise GnuplotError,"file extension is not given"
    end
  end


  # turn on debug
  def debug_on
    @debug = true
  end

  # turn off debug
  def debug_off
    @debug = false
  end

  #other_commands = %w[
  #  bind
  #  call
  #  cd
  #  do
  #  evaluate
  #  fit
  #  history
  #  if
  #  print
  #  pwd
  #  reread
  #  save
  #  shell
  #  stats
  #  system
  #  test
  #  update
  #  while
  #]

  # for irb workspace name
  def to_s
    "gnuplot"
  end

  # private methods

  def run(s,data=nil)
    res = send_cmd(s,data)
    if !res.empty?
      if res.size > 7
        msg = "\n"+res[0..5].join("")+" :\n"
      else
        msg = "\n"+res.join("")
      end
      kernel_raise GnuplotError,msg
    end
    nil
  end
  private :run

  def send_cmd(s,data=nil)
    puts "<"+s if @debug
    @iow.puts s
    @iow.puts data
    @iow.flush
    @iow.puts "print '_end_of_cmd_'"
    @iow.flush
    @history << s
    @last_message = []
    while line=@ior.gets
      puts ">"+line if @debug
      break if /^_end_of_cmd_$/ =~ line
      @last_message << line
    end
    @last_message
  end
  private :send_cmd

  def parse_plot_args(cmd,args)
    cPlotItem = (cmd == "plot") ? PlotItem : SPlotItem
    list = [[],cPlotItem.new] # first item is range
    item = list.last
    args.each do |arg|
      case arg
      when Range
        list.first << arg
      when Array
        if arg.all?{|e| e.kind_of?(Range)}
          list.first.concat(arg)
        elsif PlotItem.is_data(arg)
          item << arg
        else
          list.pop if list.last.empty?
          list << item = cPlotItem.new(*arg) # next PlotItem
        end
      when Hash
        item << arg
        list << item = cPlotItem.new # next PlotItem
      else
        item << arg
      end
    end
    list.pop if list.last.empty?
    return list
  end
  private :parse_plot_args


  # @private
  module OptArg # :nodoc: all

    module_function

    def parse(*opts)
      sep = ","
      opts.map do |opt|
        sep = " " if !opt.kind_of?(Numeric)
        case opt
        when Array
          opt.map{|v| "#{parse(*v)}"}.join(sep)
        when Hash
          opt.map{|k,v| parse_kv(k,v)}.compact.join(" ")
        when Range
          "[#{opt.begin}:#{opt.end}]"
        else
          opt.to_s
        end
      end.join(sep)
    end

    NEED_QUOTE = %w[
      background
      cblabel
      clabel
      commentschars
      dashtype
      decimalsign
      dt
      font
      fontpath
      format
      format_cb
      format_x
      format_x2
      format_xy
      format_y
      format_y2
      format_z
      locale
      logfile
      missing
      output
      print
      rgb
      separator
      table
      timefmt
      title
      x2label
      xlabel
      y2label
      ylabel
      zlabel
      cb
      x
      xy
      x2
      y
      y2
      z
    ]

    def NEED_QUOTE.===(k)
      re = /^#{k}/
      any?{|q| re =~ q}
    end

    def parse_kv(k,v)
      case k.to_sym
      when :at
        case v
        when String
          "#{k} #{v.inspect}"
        when Array
          "#{k} #{v.map{|x| x.inspect}.join(",")}"
        else
          "#{k} #{parse(v)}"
        end
      when :label
        case v
        when String
          "#{k} #{v.inspect}"
        when Array
          if v[0].kind_of?(Integer) && v[1].kind_of?(String)
            "#{k} #{parse(v[0],v[1].inspect,*v[2..-1])}"
          elsif v[0].kind_of?(String)
            "#{k} #{parse(v[0].inspect,*v[1..-1])}"
          else
            "#{k} #{parse(*v)}"
          end
        else
          "#{k} #{parse(v)}"
        end
      when NEED_QUOTE
        case v
        when String
          "#{k.to_s.sub(/_/,' ')} #{v.inspect}"
        when Array
          "#{k} #{v[0].inspect} #{parse(*v[1..-1])}"
        else
          "#{k} #{parse(v)}"
        end
      else
        case v
        when String
          "#{k} #{v}"
        when TrueClass
          "#{k}"
        when NilClass
          nil
        when FalseClass
          nil
        when Array
          if /^#{k}/ =~ "using"
            "#{k} #{v.join(':')}"
          else
            "#{k} #{parse(*v)}"
          end
        else
          "#{k} #{parse(v)}"
        end
      end
    end

  end # OptArg


  # @private
  class PlotItem # :nodoc: all

    def self.is_data(a)
      if a.kind_of? Array
        if a.last.kind_of?(Hash)
          return false
        else
          t = a.first.class
          t = Numeric if t < Numeric
          return a.all?{|e| e.kind_of?(t)}
        end
      elsif defined?(Numo::NArray)
        return true if a.kind_of?(Numo::NArray)
      elsif defined?(::NArray)
        return true if a.kind_of?(::NArray)
      elsif defined?(::NMatrix)
        return true if a.kind_of?(::NMatrix)
      end
      false
    end

    def initialize(*items)
      @items = items
    end

    def <<(item)
      @items << item
    end

    def empty?
      @items.empty?
    end

    def parse_items
      if !@options
        if @items.empty?
          return
        elsif @items.first.kind_of? String
          @function = @items.first
          @options = @items[1..-1]
          if (o=@items.last).kind_of? Hash
            if o.any?{|k,v| /^#{k}/ =~ "using"}
              # @function is data file
              @function = "'#{@function}'"
            end
          end
        else
          data = []
          @options = []
          @items.each do |x|
            if PlotItem.is_data(x)
              data << x
            else
              @options << x
            end
          end
          @data = parse_data(data)
        end
      end
    end

    def parse_data(data)
      PlotData.new(*data)
    end

    def cmd_str
      parse_items
      if @function
        "%s %s" % [@function, OptArg.parse(*@options)]
      else
        "%s %s" % [@data.cmd_str, OptArg.parse(*@options)]
      end
    end

    def data_str
      parse_items
      if @function
        nil
      else
        @data.data_str
      end
    end

  end # PlotItem


  # @private
  class SPlotItem < PlotItem  # :nodoc: all
    def parse_data(data)
      if data.size == 1
        if data[0].respond_to?(:shape)
          SPlotArray.new(*data)
        else
          PlotData.new(*data)
        end
      else
        SPlotRecord.new(*data)
      end
    end
  end


  # @private
  class PlotData  # :nodoc: all
    def data_format
      @data_format || DATA_FORMAT
    end

    def initialize(*data)
      @data = data.map{|a| a.flatten}
      @n = @data.map{|a| a.size}.min
      @text = true
    end

    def cmd_str
      if @text
        "'-'"
      else
        "'-' binary record=#{@n} format='%float64'"
      end
    end

    def data_str
      if @text
        s = ""
        @n.times{|i| s << line_str(i)+"\n"}
        s + "e"
      elsif defined? Numo::NArray
        m = @data.size
        x = Numo::DFloat.zeros(@n,m)
        m.times{|i| x[true,i] = @data[i][0...@n]}
        x.to_string
      else
        s = []
        @n.times{|i| s.concat @data.map{|a| a[i]}}
        s.pack("d*")
      end
    end

    def line_str(i)
      @data.map do |a|
        v = a[i]
        case v
        when Float,Rational
          s = data_format % v
        when Numeric
          s = v.to_s
        else
          s = v.to_s
          if /"/ =~ s
            kernel_raise GnuplotError,"should not include double quotation in data"
          else
            s = '"'+s+'"'
          end
        end
        s
      end.join(" ")
    end

    def self.array_shape(a)
      if a.kind_of?(Array)
        is_2d = true
        is_1d = true
        size_min = nil
        a.each do |b|
          if b.kind_of?(Array)
            is_1d = false
            if b.any?{|c| c.kind_of?(Array)}
              is_2d = false
            elsif size_min.nil? || b.size < size_min
              size_min = b.size
            end
          else
            is_2d = false
          end
          break if !is_1d && !is_2d
        end
        if is_1d
          [a.size]
        elsif is_2d
          [a.size, size_min]
        else
          kernel_raise GnuplotError, "not suitable Array for data"
        end
      elsif a.respond_to?(:shape)
        a.shape
      else
        kernel_raise GnuplotError, "not suitable type for data"
      end
    end
  end

  # @private
  class SPlotRecord < PlotData  # :nodoc: all

    def initialize(x,y,z)
      @text = false
      @data = [x,y,z].map{|a| a.flatten}
      @n = @data.map{|a| a.size}.min
      shape = PlotData.array_shape(z)
      if shape.size >= 2
        n = shape[1]*shape[0]
        if @n < n
          kernel_raise GnuplotError, "data size mismatch"
        end
        @n = n
        @record = "#{shape[1]},#{shape[0]}"
      else
        @record = "#{@n}"
      end
    end

    def cmd_str
      if @text
        "'-'"
      else
        "'-' binary record=(#{@record}) format='%float64' using 1:2:3"
      end
    end
  end

  # @private
  class SPlotArray < PlotData  # :nodoc: all
    def initialize(data)
      @data = data
    end

    def cmd_str
      if @text
        "'-' matrix"
      else
        s = @data.shape
        "'-' binary array=(#{s[1]},#{s[0]}) format='%float64'"
      end
    end

    def data_str
      if @text
        f = data_format
        s = ""
        a.each do |b|
          s << b.map{|e| f%e}.join(" ")+"\n"
        end
        s+"\ne"
      elsif defined? Numo::NArray
        Numo::DFloat.cast(@data).to_string
      else
        @data.to_a.flatten.pack("d*")
      end
    end
  end

end # Numo::Gnuplot
end

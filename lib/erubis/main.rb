###
### $Rev$
### $Release$
### $Copyright$
###

require 'yaml'
require 'erubis'
require 'erubis/tiny'
require 'erubis/engine/enhanced'
require 'erubis/engine/optimized'
require 'erubis/engine/eruby'
require 'erubis/engine/ephp'
require 'erubis/engine/ec'
require 'erubis/engine/ejava'
require 'erubis/engine/escheme'
require 'erubis/engine/eperl'
require 'erubis/engine/ejavascript'


module Erubis


  Ejs = Ejavascript
  EscapedEjs = EscapedEjavascript


  class CommandOptionError < ErubisError
  end


  ##
  ## main class of command
  ##
  ## ex.
  ##   Main.main(ARGV)
  ##
  class Main

    def self.main(argv=ARGV)
      status = 0
      begin
        Main.new.execute(ARGV)
      rescue CommandOptionError => ex
        $stderr.puts ex.message
        status = 1
      end
      exit(status)
    end

    def initialize
      @single_options = "hvxTtSbeB"
      @arg_options    = "pcrfKIlaEC"
      @option_names   = {
        ?h => :help,
        ?v => :version,
        ?x => :source,
        ?T => :notrim,
        ?t => :untabify,
        ?S => :intern,
        ?b => :bodyonly,
        ?B => :binding,
        ?p => :pattern,
        ?c => :context,
        ?C => :class,
        ?e => :escape,
        ?r => :requires,
        ?f => :datafiles,
        ?K => :kanji,
        ?I => :includes,
        ?l => :lang,
        ?a => :action,
        ?E => :enhancers,
      }
      assert unless @single_options.length + @arg_options.length == @option_names.length
      (@single_options + @arg_options).each_byte do |ch|
        assert unless @option_names.key?(ch)
      end
    end


    def execute(argv=ARGV)
      ## parse command-line options
      options, properties = parse_argv(argv, @single_options, @arg_options)
      filenames = argv
      options[?h] = true if properties[:help]
      opts = Object.new
      arr = @option_names.collect { |ch, name| "def #{name}; @#{name}; end\n" }
      opts.instance_eval arr.join
      options.each do |ch, val|
        name = @option_names[ch]
        opts.instance_variable_set("@#{name}", val)
      end

      ## help, version, enhancer list
      if opts.help || opts.version
        puts version()         if opts.version
        puts usage()           if opts.help
        puts show_properties() if opts.help
        puts show_enhancers()  if opts.help
        return
      end

      ## include path
      opts.includes.split(/,/).each do |path|
        $: << path
      end if opts.includes

      ## require library
      opts.requires.split(/,/).each do |library|
        require library
      end if opts.requires

      ## action
      action = opts.action
      action ||= 'convert' if opts.source

      ## lang
      lang = opts.lang || 'ruby'
      action ||= 'convert' if opts.lang

      ## class name of Eruby
      classname = opts.class
      klass = get_classobj(classname, lang, properties[:pi])

      ## kanji code
      $KCODE = opts.kanji if opts.kanji

      ## read context values from yaml file
      datafiles = opts.datafiles
      context = load_datafiles(datafiles, opts)

      ## parse context data
      if opts.context
        context = parse_context_data(opts.context, opts)
      end

      ## properties for engine
      properties[:escape]   = true         if opts.escape && !properties.key?(:escape)
      properties[:pattern]  = opts.pattern if opts.pattern
      properties[:trim]     = false        if opts.notrim
      properties[:preamble] = properties[:postamble] = false if opts.bodyonly
      properties[:pi]       = nil          if properties[:pi] == true

      ## create engine and extend enhancers
      engine = klass.new(nil, properties)
      enhancers = get_enhancers(opts.enhancers)
      #enhancers.push(Erubis::EscapeEnhancer) if opts.escape
      enhancers.each do |enhancer|
        engine.extend(enhancer)
        engine.bipattern = properties[:bipattern] if enhancer == Erubis::BiPatternEnhancer
      end

      ## convert and execute
      val = nil
      if filenames && !filenames.empty?
        filenames.each do |filename|
          test(?f, filename)  or raise CommandOptionError.new("#{filename}: file not found.")
          engine.filename = filename
          engine.convert!(File.read(filename))
          print val if val = do_action(action, engine, context, opts)
        end
      else
        engine.filename = '(stdin)'
        engine.convert!($stdin.read())
        print val if val = do_action(action, engine, context, opts)
      end

    end

    private

    def do_action(action, engine, context, opts)
      case action
      when 'convert'
        s = engine.src
      when nil, 'exec', 'execute'
        s = opts.binding ? engine.result(context) : engine.evaluate(context)
      else
        raise "*** internal error"
      end
      return s
    end

    def usage
      command = File.basename($0)
      s = <<END
erubis - embedded program converter for multi-language
Usage: #{command} [..options..] [file ...]
  -h, --help    : help
  -v            : version
  -x            : converted code
  -T            : don't trim spaces around '<% %>'
  -b            : body only (no preamble nor postamble)
  -e            : escape (equal to '--E Escape')
  -p pattern    : embedded pattern (default '<% %>')
  -l lang       : convert but no execute (ruby/php/c/java/scheme/perl/js)
  -E e1,e2,...  : enhancer names (Escape, PercentLine, BiPattern, ...)
  -I path       : library include path
  -K kanji      : kanji code (euc/sjis/utf8) (default none)
  -c context    : context data string (yaml inline style or ruby code)
  -f datafile   : context data file ('*.yaml', '*.yml', or '*.rb')
  -t            : expand tab character in YAML file
  -S            : convert mapping key from string to symbol in YAML file
  -B            : invoke 'result(binding)' instead of 'evaluate(context)'
  --pi=name     : parse '<?name ... ?>' instead of '<% ... %>'

END
      #'
      #  -c class      : class name (XmlEruby/PercentLineEruby/...) (default Eruby)
      #  -r library    : require library
      #  -a            : action (convert/execute)
      return s
    end


    def collect_supported_properties(erubis_klass)
      list = []
      erubis_klass.ancestors.each do |klass|
        if klass.respond_to?(:supported_properties)
          list.concat(klass.supported_properties)
        end
      end
      return list
    end

    def show_properties
      s = "supported properties:\n"
      basic_props = collect_supported_properties(Erubis::Basic::Engine)
      pi_props    = collect_supported_properties(Erubis::PI::Engine)
      list = []
      common_props = basic_props & pi_props
      list << ['(common)', common_props]
      list << ['(basic)',  basic_props - common_props]
      list << ['(pi)',     pi_props    - common_props]
      %w[ruby php c java scheme perl javascript].each do |lang|
        klass = Erubis.const_get("E#{lang}")
        list << [lang, collect_supported_properties(klass) - basic_props]
      end
      list.each do |lang, props|
        s << "  * #{lang}\n"
        props.each do |name, default_val, desc|
          s << ("     --%-23s : %s\n" % ["#{name}=#{default_val.inspect}", desc])
        end
      end
      s << "\n"
      return s
    end

    def show_enhancers
      s = "enhancers:\n"
      list = []
      ObjectSpace.each_object(Module) do |m| list << m end
      list.sort_by { |m| m.name }.each do |m|
        next unless m.name =~ /\AErubis::(.*)Enhancer\z/
        name = $1
        desc = m.desc
        s << ("  %-13s : %s\n" % [name, desc])
      end
      return s
    end

    def version
      release = ('$Release: 0.0.0 $' =~ /([.\d]+)/) && $1
      return release
    end

    def parse_argv(argv, arg_none='', arg_required='', arg_optional='')
      options = {}
      context = {}
      while argv[0] && argv[0][0] == ?-
        optstr = argv.shift
        optstr = optstr[1, optstr.length-1]
        #
        if optstr[0] == ?-    # context
          unless optstr =~ /\A\-([-\w]+)(?:=(.*))?/
            raise CommandOptionError.new("-#{optstr}: invalid context value.")
          end
          name = $1;  value = $2
          name  = name.gsub(/-/, '_').intern
          #value = value.nil? ? true : YAML.load(value)   # error, why?
          value = value.nil? ? true : YAML.load("---\n#{value}\n")
          context[name] = value
          #
        else                  # options
          while optstr && !optstr.empty?
            optchar = optstr[0]
            optstr[0,1] = ""
            if arg_none.include?(optchar)
              options[optchar] = true
            elsif arg_required.include?(optchar)
              arg = optstr.empty? ? argv.shift : optstr
              unless arg
                mesg = "-#{optchar.chr}: #{@option_args[optchar]} required."
                raise CommandOptionError.new(mesg)
              end
              options[optchar] = arg
              optstr = nil
            elsif arg_optional.include?(optchar)
              arg = optstr.empty? ? true : optstr
              options[optchar] = arg
              optstr = nil
            else
              raise CommandOptionError.new("-#{optchar.chr}: unknown option.")
            end
          end
        end
        #
      end  # end of while

      return options, context
    end


    def untabify(str, width=8)
      list = str.split(/\t/)
      last = list.pop
      sb = ''
      list.each do |s|
        column = (n = s.rindex(?\n)) ? s.length - n - 1 : s.length
        n = width - (column % width)
        sb << s << (' ' * n)
      end
      sb << last
      return sb
    end
    #--
    #def untabify(str, width=8)
    #  sb = ''
    #  str.scan(/(.*?)\t/m) do |s, |
    #    len = (n = s.rindex(?\n)) ? s.length - n - 1 : s.length
    #    sb << s << (" " * (width - len % width))
    #  end
    #  return $' ? (sb << $') : str
    #end
    #++


    def get_classobj(classname, lang, pi)
      classname ||= "E#{lang}"
      base_module = pi ? Erubis::PI : Erubis
      begin
        klass = base_module.const_get(classname)
      rescue NameError
        klass = nil
      end
      unless klass
        if lang
          msg = "-l #{lang}: invalid language name (class #{base_module.name}::#{classname} not found)."
        else
          msg = "-c #{classname}: invalid class name."
        end
        raise CommandOptionError.new(msg)
      end
      return klass
    end

    def get_enhancers(enhancer_names)
      return [] unless enhancer_names
      enhancers = []
      shortname = nil
      begin
        enhancer_names.split(/,/).each do |shortname|
          enhancers << Erubis.const_get("#{shortname}Enhancer")
        end
      rescue NameError
        raise CommandOptionError.new("#{shortname}: no such Enhancer (try '-E' to show all enhancers).")
      end
      return enhancers
    end

    def load_datafiles(filenames, opts)
      context = Erubis::Context.new
      return hash unless filenames
      filenames.split(/,/).each do |filename|
        filename.strip!
        test(?f, filename) or raise CommandOptionError.new("#{filename}: file not found.")
        if filename =~ /\.ya?ml$/
          if opts.untabify
            str = YAML.load(untabify(File.read(filename)))
            ydoc = YAML.load(str)
          else
            ydoc = YAML.load_file(filename)
          end
          ydoc.is_a?(Hash) or raise CommandOptionError.new("#{filename}: root object is not a mapping.")
          intern_hash_keys(ydoc) if opts.intern
          context.update(ydoc)
        elsif filename =~ /\.rb$/
          str = File.read(filename)
          context2 = Erubis::Context.new
          _instance_eval(context2, str)
          context.update(context2)
        else
          CommandOptionError.new("#{filename}: '*.yaml', '*.yml', or '*.rb' required.")
        end
      end
      return context
    end

    def _instance_eval(_context, _str)
      _context.instance_eval(_str)
    end

    def parse_context_data(context_str, opts)
      if context_str[0] == ?{
        require 'yaml'
        ydoc = YAML.load(context_str)
        unless ydoc.is_a?(Hash)
          raise CommandOptionError.new("-c: root object is not a mapping.")
        end
        intern_hash_keys(ydoc) if opts.intern
        return ydoc
      else
        context = Erubis::Context.new
        context.instance_eval(context_str, '-c')
        return context
      end
    end

    def intern_hash_keys(obj, done={})
      return if done.key?(obj.__id__)
      case obj
      when Hash
        done[obj.__id__] = obj
        obj.keys.each do |key|
          obj[key.intern] = obj.delete(key) if key.is_a?(String)
        end
        obj.values.each do |val|
          intern_hash_keys(val, done) if val.is_a?(Hash) || val.is_a?(Array)
        end
      when Array
        done[obj.__id__] = obj
        obj.each do |val|
          intern_hash_keys(val, done) if val.is_a?(Hash) || val.is_a?(Array)
        end
      end
    end

  end

end

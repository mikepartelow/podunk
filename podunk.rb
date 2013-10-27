#!/bin/env ruby

require 'open-uri'
require 'syndication/rss'
require 'json'
require 'time'
require 'erb'
require 'sanitize'
require 'fileutils'
require 'time'
require 'net/http'

DEV_MODE = true
DEV_MODE_ERRORS = false

class Episode
  attr_reader :remote_path, :local_path, :title, :summary, :published_at, :downloaded_at

  def initialize(attrs)
    attrs.each do |k, v| 
      if k.to_s =~ /_at$/ && v.is_a?(String)
        v = Time.parse(v)
      end
      instance_variable_set "@#{k}", v
    end
  end
  
  def to_json(state)
    values = instance_variables.map do |name|
      [ name.to_s[1..-1].to_sym, instance_variable_get(name) ]
    end

    JSON.pretty_generate(Hash[values], state)
  end
end

class Podunk
  CFG_PATH = 'podunk.cfg'
  DB_PATH = '.podunkdb.json'
  INDEX_ERB_PATH = 'erb/index.html.erb'
  INDEX_PATH = 'www/index.html'
  DEFAULT_CONFIG = { :podcast_dir => '/tmp' }
  
  def initialize
    @db = load_db
    
    raise ArgumentError.new("Could not locate #{CFG_PATH}. Please define some feeds.") unless File.exists? CFG_PATH
    @cfg = parse_config!(open(CFG_PATH) { |f| f.read })

    log "Using Podcast Dir: #{@cfg[:podcast_dir]}"    
    FileUtils.mkdir_p @cfg[:podcast_dir]   
  end
  
  def fetch!
    @db.select { |feed_name, data| data[:subscribed?] }.each do |feed_name, data|
      log "Updating Feed #{feed_name}"
          
      podcast_root = File.join(@cfg[:podcast_dir], feed_name)      
      FileUtils.mkdir_p podcast_root
          
      if DEV_MODE
        cache_path = feed_name.gsub(' ', '_') + '.cache'
              
        unless File.exists? cache_path
          open(cache_path, 'w') { |ff| ff.write(open(data[:url]) { |fu| fu.read }) }
        end
      
        rss = open(cache_path) { |f| f.read }
      else
        rss = open(data[:url]) { |fu| fu.read }
      end
                
      feed = Syndication::RSS::Parser.new.parse(rss)
           
      feed.items.each do |i|
        filename = "%s %s.mp3" % [ i.pubdate.strftime("%Y%m%d_%H%M%S"), sanitize_filename(i.title) ]
        local_path = File.realdirpath(File.join(podcast_root, filename))
        
        episode_hash = { :remote_path    => i.enclosure.url,
                         :local_path     => local_path,
                         :title          => i.title,
                         :summary        => Sanitize::clean(i.description),
                         :published_at   => i.pubdate,
                         :downloaded_at  => nil }
    
        
        if episode = fetch_episode!(episode_hash, data[:episodes])
          data[:episodes] << episode
        end
      end
    end    
  end
  
  def write_index!
    the_html = ERB.new(open(INDEX_ERB_PATH) { |f| f.read }).result(binding)
    open(INDEX_PATH, 'w') { |f| f.write(the_html) }
  end
  
  def save!
    the_json = JSON.pretty_generate(@db)
    open(DB_PATH, 'w') { |f| f.write(the_json) }
  end
  
  private
    def log(str)
      puts str
    end
    
    def fetch_episode!(episode, episodes)
      retval = nil
      
      begin
        if DEV_MODE && DEV_MODE_ERRORS && rand(5) == 2
          raise IOError
        end
                
        unless episode[:remote_path] =~ /\.mp3$/
          log "WARNING: Skipping Unsupported File: #{episode[:remote_path]}"
          return
        end

        if episodes.find { |e| e.remote_path == episode[:remote_path] }
          # our db already has an entry for this episode
          #
          if File.exists? episode[:local_path]
            log "  s #{episode[:remote_path]}"
          else
            log "  x #{episode[:remote_path]}"
            episode[:local_path] = nil
          end            
          return
        end
         
        if File.exists? episode[:local_path]
          log "  e #{episode[:remote_path]}"
          episode[:downloaded_at] = Time.now                    
        else
          if DEV_MODE
            open(episode[:local_path], 'w') { |f| f.write("stub") }
          else
            stream! episode[:remote_path], episode[:local_path]
          end

          episode[:downloaded_at] = Time.now
          log "  + #{episode[:remote_path]}"
        end 
    
        retval = Episode.new(episode)                                   
      rescue Exception => e
        log "EXCEPTION while fetching #{episode[:remote_path]}: #{e}"
      end      
      
      retval
    end
    
    def stream!(remote_path, local_path)
      uri = URI(remote_path)      

      Net::HTTP.start(uri.host, uri.port) do |http|
        request = Net::HTTP::Get.new(uri.request_uri)

        http.request(request) do |response|
          # if %w|301 302|.include?(response.code) # moved permanently, moved temporarily            
          if response.kind_of?(Net::HTTPRedirection)                
            stream! response['location'], local_path
          elsif response.code != '200'
            raise IOError.new(response.inspect)
          else
            open(local_path, 'w') do |f|
              response.read_body do |chunk|
                f.write chunk
              end
            end
          end
        end
      end
    end
    
    def sanitize_filename(str)
      str.gsub /[^ A-Za-z0-9\.'"?!\(\)\[\]]/, ''
    end
    
    def date(time)
      time ? time.strftime("%Y/%m/%d") : ''
    end
    
    def load_db
      if File.exists? DB_PATH
        db = JSON.parse(open(DB_PATH) { |f| f.read }, :symbolize_names => true)
        db = Hash[db.map { |k, v| [ k.to_s, v ] }] # we want symbolic names for everything except the feed names
        db.each do |feed_name, data|
          data[:episodes] = data[:episodes].map { |attrs| Episode.new(attrs) }
          data[:subscribed?] = false
        end
      else
        db = {}
      end 
      
      db
    end
      
    def parse_config!(text)
      cfg = DEFAULT_CONFIG
      
      text.lines.each do |line|
        next if line =~ /^#/ || line =~ /^\s*$/
      
        opt, the_rest = line.split(/\s+/, 2).map(&:strip)
        case opt
        when 'podcast_dir'
          cfg[:podcast_dir] = the_rest
        when 'feed'
          name, url = the_rest.split(/\=>/, 2).map(&:strip)
          if @db[name]
            @db[name][:url] = url
          else
            @db[name] = { :url => url, :episodes => [] }
          end
          
          @db[name][:subscribed?] = true
        end
      end
    
      cfg
    end  
end

p = Podunk.new
p.fetch!
p.write_index!
p.save!

__END__

BUGS:
 - no "resume" or "check" if podcasts were interrupted during download
 - prettify index.html
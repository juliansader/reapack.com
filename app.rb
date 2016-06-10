require 'action_view'
require 'em-http'
require 'em-http/middleware/json_response'
require 'ostruct'
require 'sass/plugin/rack'
require 'sinatra/base'
require 'time'

Sass::Plugin.options.merge! \
  sourcemap: :none,
  style: :compressed

ReaPack = Class.new

class ReaPack::WebApp < Sinatra::Base
  UPDATE_INTERVAL = 24
  URL = 'https://api.github.com/repos/cfillion/reapack/releases'
  DOWNLOADS = true

  def initialize
    @@boot_time = Time.now
    @@last_update = Time.new 0
    @@last_response = nil
    @@latest = @@downloads = nil

    if DOWNLOADS
      interval = UPDATE_INTERVAL * 60 * 60
      EM::next_tick { EM.add_periodic_timer interval, method(:update) }
    end

    super
  end

  def make_request
    client = EventMachine::HttpRequest.new URL
    client.use EM::Middleware::JSONResponse
    client.get
  end

  def update(force = false)
    now = Time.now
    return false if !force && @@last_update > now - 3600

    @@last_update = now

    req = make_request
    req.errback {
      @@last_response = req.error
    }

    req.callback {
      next unless req.response_header.status == 200
      @@last_response = req.response_header

      releases = []
      req.response.each {|json_release|
        release = make_release json_release
        releases << release
      }

      harvest_data releases
    }

    true
  end

  def make_release(json)
    release = OpenStruct.new
    release.name = json['tag_name'].to_s
    release.stable = !json['prerelease']
    release.url = json['html_url'].to_s
    release.author = json['author'].to_h['login'].to_s
    release.time = DateTime.rfc3339 json['published_at']
    release.downloads = 0

    json['assets'].to_a.each {|json_asset|
      asset = make_asset json_asset
      release.downloads += asset.downloads if DOWNLOADS

      case asset.name
      when 'reaper_reapack32.dylib'
        release.darwin32 = asset
      when 'reaper_reapack64.dylib'
        release.darwin64 = asset
      when 'reaper_reapack32.dll'
        release.win32 = asset
      when 'reaper_reapack64.dll'
        release.win64 = asset
      end
    }

    release
  end

  def make_asset(json)
    asset = OpenStruct.new
    asset.name = json['name']
    asset.url = json['browser_download_url']
    asset.size = json['size'].to_i
    asset.downloads = json['download_count'].to_i

    asset
  end

  def harvest_data(releases)
    return if releases.empty?

    @@latest = releases.find {|r| r.stable }
    @@latest ||= releases.first

    @@downloads = releases.map {|r| r.downloads }.inject(&:+) if DOWNLOADS

    [:darwin32, :darwin64, :win32, :win64].each {|var|
      next if @@latest[var]
      match = releases.find {|r| r[var] && (r.stable || !@@latest.stable) }
      @@latest[var] = match[var] if match
    }
  end

  use Sass::Plugin::Rack

  include ActionView::Helpers::NumberHelper

  get '/' do
    if @@latest
      last_modified @@last_update
      @latest = @@latest
      @downloads = @@downloads
    else
      update
    end

    slim :index
  end

  post '/sync' do
    content_type 'text/plain'
    if update request.user_agent =~ /\AGitHub-Hookshot\//
      'Refreshing the release feed now!'
    else
      'No.'
    end
  end

  get '/debug' do
    content_type 'text/plain'
    headers['X-Last-Update'] = @@last_update.to_s
    headers['X-Server-Started'] = @@boot_time.to_s

    case @@last_response
    when NilClass
      [200, 'No request made yet.']
    when String
      [500, @@last_response]
    else
      [
        @@last_response.status,
        @@last_response.map {|k, v| "%s: %s\n" % [k, v] }
      ]
    end
  end

  not_found do
    slim :not_found
  end
end

# Copyright (c) 2012 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'json'
require 'net/http'
require 'uri'

module Wallaroo
  module Client
    module Util
      private
      def fatal(message, code=nil)
        raise "#{message}, #{code}"
      end
      
      # for backwards-compatibility with ported Wallaby code
      def fail(code, message)
        fatal(message, code)
      end
      
      def current_caller
        caller[1] =~ /`([^']*)'/ and $1
      end
          
      def not_implemented
        fatal "#{self.class.name}##{current_caller} is not implemented"
      end
      
      def self.camelcase(str)
        str.capitalize.gsub(/_([a-z])/) {|match| match[1].chr.upcase}
      end
      
    end
    
    class ConnectionMeta
      DEFAULTS = {:host=>"localhost", :port=>8000, :scheme=>"http", :username=>"", :pw=>""}

      attr_reader :host, :port, :scheme, :username, :pw, :how
      def initialize(options=nil)
        options ||= {}
        options = DEFAULTS.merge(options)
        %w{host port scheme username pw}.each do |attribute|
          self.instance_variable_set("@#{attribute}", options[attribute.to_sym])
        end
        @how = Proxying.mk_how(options)
      end
      
      def make_proxy_object(kind, name)
        klazz = ::Wallaroo::Client.const_get(kind.to_s.capitalize)
        result = klazz.new("/#{kind.to_s.downcase}s/#{name}", self)
        result.name = name
        result
      end
    end
    
    module Proxying
      class How
        attr_accessor :how, :what
        
        def initialize(how, what)
          @how = how
          @what = what
        end
        
        def to_q
          "#{how.to_s}=#{URI.encode(what)}"
        end
        
        def update!(sha)
          return if how == :branch          
          self.how = :commit
          self.what = sha
        end
      end
      
      def self.mk_how(options)
        [:branch, :tag, :commit].map do |kind| 
          what = options[kind] 
          what ? How.new(kind, what) : nil
        end.find(Proc.new {How.new(:tag, "current")}) {|v| v != nil }
      end
      
      module CM
        def declare_attribute(name, readonly=nil)
          ensure_accessors
          attributes << name.to_s
          getter_name = "#{name}".to_sym
          setter_name = "#{name}=".to_sym
          
          self.class_eval do
            define_method getter_name do
              attr_vals[name]
            end
            
            unless readonly
              define_method setter_name do |new_val|
                attr_vals[name] = new_val
              end
            end
          end
        end
        
        def ensure_accessors
          unless self.respond_to? :attributes
            class << self
              attr_accessor :attributes
            end
            self.attributes ||= []
          end
        end
      end
      
      module IM
        def initialize(path, cm)
          @path = path
          @cm = cm
          @attr_vals = {}
        end

        def exists?
          response = Net::HTTP.get_response(url)
          return response.code != "404"
        end
      
        def refresh
          response = Net::HTTP.get_response(url)
          unless response.code == "200"
            # XXX: improve error handling to be on par with QMF client
            fatal response.body, response.code
          end
          
          hash = JSON.parse(response.body)
          
          self.class.attributes.each do |name|
            attr_vals[name.to_sym] = hash[name]
          end
          
          self
        end
      
        def update!
          http = Net::HTTP.new(url.host, url.port)
          request = Net::HTTP::Put.new(url.request_uri)
          request.body = attr_vals.to_json
          request.content_type = "application/json"
          
          response = http.request(request)
          
          unless response.code =~ /^2/
            fatal response.body, response.code
          end

          update_commit(response.header["location"])
          @url = nil
          self
        end
        
        def create!
          http = Net::HTTP.new(url.host, url.port)
          request = Net::HTTP::Put.new(url.request_uri)
          request.body = attr_vals.to_json
          request.content_type = "application/json"
          
          response = http.request(request)
          
          unless response.code =~ /^2/
            fatal response.body, response.code
          end

          puts "response.header['location'] is #{response.header["location"]}"

          update_commit(response.header["location"])
          @url = nil
          url
          self
        end
        
        def attr_vals
          @attr_vals
        end

        private
        def url
          # XXX invalidate this
          @url ||= URI::HTTP.new(cm.scheme, nil, cm.host, cm.port, nil, path, nil, cm.how.to_q, nil) 
        end
        
        def update_commit(location)
          puts "location is '#{location}'"
          
          match = location.match(/.*?(commit)=([0-9a-f]+)/)
          
          puts "match is #{match}"
          
          if match
            cm.how.update!(match[2])
          end
        end
      end
      
      def self.included(receiver)
        receiver.extend CM
        receiver.send :include, IM

        receiver.send :include, ::Wallaroo::Client::Util
        receiver.send :attr_accessor, :cm, :path
      end
    end   
  end
end
      
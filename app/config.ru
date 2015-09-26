require_relative './app.rb'

run Isucon5::WebApp

require 'stackprof' #if ENV['ISUPROFILE']
Dir.mkdir('/tmp/stackprof') unless File.exist?('/tmp/stackprof')
use StackProf::Middleware, enabled: true, mode: :wall, interval: 500, save_every: 100, path: '/tmp/stackprof'

#require 'gctools/oobgc'
#if defined?(Unicorn::HttpRequest)
#  use GC::OOB::UnicornMiddleware
#end

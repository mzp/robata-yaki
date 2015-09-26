require 'redis'

redis = Redis.new(:path => "/tmp/redis.sock")
redis.flushall

relations = {}
ARGF.each do |line|
  _, one, another, *_ = line.split("\t")

  relations[one] ||= []
  relations[another] ||= []
  relations[one] << another
  relations[another] << one
end

relations.each do |key, values|
  values.sort.uniq.each do|v|
    redis.rpush "friend:#{key}", v
  end
end

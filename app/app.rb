require 'sinatra/base'
require 'mysql2'
require 'mysql2-cs-bind'
require 'tilt/erubis'
require 'erubis'
require 'redis'
require 'hiredis'
require 'redis/connection/hiredis'
load 'users.rb'
require 'digest/sha2'

module Isucon5
  class AuthenticationError < StandardError; end
  class PermissionDenied < StandardError; end
  class ContentNotFound < StandardError; end
  module TimeWithoutZone
    def to_s
      strftime("%F %H:%M:%S")
    end
  end
  ::Time.prepend TimeWithoutZone
end

class Isucon5::WebApp < Sinatra::Base
  use Rack::Session::Cookie
  set :erb, escape_html: true
  set :public_folder, File.expand_path('../../static', __FILE__)
  #set :sessions, true
  set :session_secret, ENV['ISUCON5_SESSION_SECRET'] || 'beermoris'
  set :protection, true

  helpers do
    def config
      @config ||= {
        db: {
          host: ENV['ISUCON5_DB_HOST'] || 'localhost',
          port: ENV['ISUCON5_DB_PORT'] && ENV['ISUCON5_DB_PORT'].to_i,
          username: ENV['ISUCON5_DB_USER'] || 'root',
          password: ENV['ISUCON5_DB_PASSWORD'],
          database: ENV['ISUCON5_DB_NAME'] || 'isucon5q',
        },
      }
    end

    def redis
      return Thread.current[:isucon5_redis] if Thread.current[:isucon5_redis]

      redis = Redis.new(:path => "/dev/shm/redis.sock")
      Thread.current[:isucon5_redis] = redis
      redis
    end

    def db
      return Thread.current[:isucon5_db] if Thread.current[:isucon5_db]
      client = Mysql2::Client.new(
        host: config[:db][:host],
        port: config[:db][:port],
        username: config[:db][:username],
        password: config[:db][:password],
        database: config[:db][:database],
        reconnect: true,
      )
      client.query_options.merge!(symbolize_keys: true)
      Thread.current[:isucon5_db] = client
      client
    end

    def authenticate(email, password)
      user = user_from_email(email)
      unless user
        raise Isucon5::AuthenticationError
      end
      unless user[:passhash] == Digest::SHA512.hexdigest(password + user[:salt])
        raise Isucon5::AuthenticationError
      end
      session[:user_id] = user[:id]
      user
    end

    def current_user
      return @user if @user
      unless session[:user_id]
        return nil
      end
      @user = db.xquery('SELECT id, account_name, nick_name, email FROM users WHERE id=?', session[:user_id]).first
      unless @user
        session[:user_id] = nil
        session.clear
        raise Isucon5::AuthenticationError
      end
      @user
    end

    def authenticated!
      unless current_user
        redirect '/login'
      end
    end

    def get_user(user_id)
#      user = db.xquery('SELECT * FROM users WHERE id = ?', user_id).first
      user = $user_from_id[user_id.to_s]
      raise Isucon5::ContentNotFound unless user
      user
    end

    def user_from_account(account_name)
#      user = db.xquery('SELECT * FROM users WHERE account_name = ?', account_name).first
      user = $user_from_account[account_name]
      raise Isucon5::ContentNotFound unless user
      user
    end

    def user_from_email(email)
      user_from_account(email.sub("@isucon.net", ''))
    end

    def is_friend?(another_id)
      user_id = session[:user_id]
      friends(user_id).include? another_id.to_s
    end

    def friends(user_id)
      redis.lrange("friend:#{user_id}", 0, -1)
    end

    def is_friend_account?(account_name)
      is_friend?(user_from_account(account_name)[:id])
    end

    def permitted?(another_id)
      another_id == current_user[:id] || is_friend?(another_id)
    end

    def mark_footprint(user_id)
      if user_id != current_user[:id]
        query = 'INSERT INTO footprints (user_id,owner_id) VALUES (?,?)'
        db.xquery(query, user_id, current_user[:id])
      end
    end

    PREFS = %w(
      未入力
      北海道 青森県 岩手県 宮城県 秋田県 山形県 福島県 茨城県 栃木県 群馬県 埼玉県 千葉県 東京都 神奈川県 新潟県 富山県
      石川県 福井県 山梨県 長野県 岐阜県 静岡県 愛知県 三重県 滋賀県 京都府 大阪府 兵庫県 奈良県 和歌山県 鳥取県 島根県
      岡山県 広島県 山口県 徳島県 香川県 愛媛県 高知県 福岡県 佐賀県 長崎県 熊本県 大分県 宮崎県 鹿児島県 沖縄県
    )
    def prefectures
      PREFS
    end
  end

  error Isucon5::AuthenticationError do
    session[:user_id] = nil
    halt 401, erubis(:login, layout: false, locals: { message: 'ログインに失敗しました' })
  end

  error Isucon5::PermissionDenied do
    halt 403, erubis(:error, locals: { message: '友人のみしかアクセスできません' })
  end

  error Isucon5::ContentNotFound do
    halt 404, erubis(:error, locals: { message: '要求されたコンテンツは存在しません' })
  end

  get '/login' do
    session.clear
    erb :login, layout: false, locals: { message: '高負荷に耐えられるSNSコミュニティサイトへようこそ!' }
  end

  post '/login' do
    authenticate params['email'], params['password']
    redirect '/'
  end

  get '/logout' do
    session[:user_id] = nil
    session.clear
    redirect '/login'
  end

  get '/' do
    authenticated!

    profile = db.xquery('SELECT * FROM profiles WHERE user_id = ?', current_user[:id]).first

    entries_query = 'SELECT * FROM entries WHERE user_id = ? ORDER BY created_at LIMIT 5'
    entries = db.xquery(entries_query, current_user[:id])
      .map{ |entry| entry[:is_private] = (entry[:private] == 1); entry[:title], entry[:content] = entry[:body].split(/\n/, 2); entry }

    comments_for_me_query = <<SQL
SELECT c.id AS id, c.entry_id AS entry_id, c.user_id AS user_id, c.comment AS comment, c.created_at AS created_at
FROM comments c
JOIN entries e ON c.entry_id = e.id
WHERE e.user_id = ?
ORDER BY c.created_at DESC
LIMIT 10
SQL
    comments_for_me = db.xquery(comments_for_me_query, current_user[:id])

    entries_of_friends = []
    db.xquery('SELECT * FROM entries WHERE user_id in (?) ORDER BY created_at DESC LIMIT 10', [friends(current_user[:id])]).each do |entry|
      entry[:title] = entry[:body].split(/\n/).first
      entries_of_friends << entry
      break if entries_of_friends.size >= 10
    end

    comments_of_friends = []
    db.xquery('SELECT * FROM comments WHERE user_id in (?) ORDER BY created_at DESC LIMIT 10', [friends(current_user[:id])]).each do |comment|
      entry = db.xquery('SELECT * FROM entries WHERE id = ?', comment[:entry_id]).first
      entry[:is_private] = (entry[:private] == 1)
      next if entry[:is_private] && !permitted?(entry[:user_id])
      comments_of_friends << comment
      break if comments_of_friends.size >= 10
    end

    friends = friends(current_user[:id]).map {|user_id| [user_id, Time.now]}

    query = <<SQL
SELECT user_id, owner_id, DATE(created_at) AS date, MAX(created_at) AS updated
FROM footprints
WHERE user_id = ?
GROUP BY user_id, owner_id, DATE(created_at)
ORDER BY updated DESC
LIMIT 10
SQL
    footprints = db.xquery(query, current_user[:id])

    locals = {
      profile: profile || {},
      entries: entries,
      comments_for_me: comments_for_me,
      entries_of_friends: entries_of_friends,
      comments_of_friends: comments_of_friends,
      friends: friends,
      footprints: footprints
    }
    erb :index, locals: locals
  end

  get '/profile/:account_name' do
    authenticated!
    owner = user_from_account(params['account_name'])
    prof = db.xquery('SELECT * FROM profiles WHERE user_id = ?', owner[:id]).first
    prof = {} unless prof
    query = if permitted?(owner[:id])
              'SELECT * FROM entries WHERE user_id = ? ORDER BY created_at LIMIT 5'
            else
              'SELECT * FROM entries WHERE user_id = ? AND private=0 ORDER BY created_at LIMIT 5'
            end
    entries = db.xquery(query, owner[:id])
      .map{ |entry| entry[:is_private] = (entry[:private] == 1); entry[:title], entry[:content] = entry[:body].split(/\n/, 2); entry }
    mark_footprint(owner[:id])
    erb :profile, locals: { owner: owner, profile: prof, entries: entries, private: permitted?(owner[:id]) }
  end

  post '/profile/:account_name' do
    authenticated!
    if params['account_name'] != current_user[:account_name]
      raise Isucon5::PermissionDenied
    end
    args = [params['first_name'], params['last_name'], params['sex'], params['birthday'], params['pref']]

    prof = db.xquery('SELECT * FROM profiles WHERE user_id = ?', current_user[:id]).first
    if prof
      query = <<SQL
UPDATE profiles
SET first_name=?, last_name=?, sex=?, birthday=?, pref=?, updated_at=CURRENT_TIMESTAMP()
WHERE user_id = ?
SQL
      args << current_user[:id]
    else
      query = <<SQL
INSERT INTO profiles (user_id,first_name,last_name,sex,birthday,pref) VALUES (?,?,?,?,?,?)
SQL
      args.unshift(current_user[:id])
    end
    db.xquery(query, *args)
    redirect "/profile/#{params['account_name']}"
  end

  get '/diary/entries/:account_name' do
    authenticated!
    owner = user_from_account(params['account_name'])
    query = if permitted?(owner[:id])
              'SELECT ent.id as id,ent.user_id as user_id,ent.private as privat0e,ent.body as body,ent.created_at as created_at,count(c.id) as comment_count ' +
              'from (SELECT * FROM entries WHERE user_id = ? ORDER BY created_at DESC LIMIT 20) ent ' +
              'left join comments c ON ent.id = c.entry_id ' +
              'GROUP BY ent.id, ent.user_id,ent.private,ent.body,ent.created_at ' +
              'ORDER BY ent.created_at desc'
            else
              'SELECT ent.id as id,ent.user_id as user_id,ent.private as privat0e,ent.body as body,ent.created_at as created_at,count(c.id) as comment_count ' +
              'from (SELECT * FROM entries WHERE user_id = ? AND private=0 ORDER BY created_at DESC LIMIT 20) ent ' +
              'left join comments c ON ent.id = c.entry_id ' +
              'GROUP BY ent.id, ent.user_id,ent.private,ent.body,ent.created_at ' +
              'ORDER BY ent.created_at desc'
            end
    entries = db.xquery(query, owner[:id])
      .map{ |entry| entry[:is_private] = (entry[:private] == 1); entry[:title], entry[:content] = entry[:body].split(/\n/, 2); entry }
    mark_footprint(owner[:id])
    erb :entries, locals: { owner: owner, entries: entries, myself: (current_user[:id] == owner[:id]) }
  end

  get '/diary/entry/:entry_id' do
    authenticated!
    entry = db.xquery('SELECT * FROM entries WHERE id = ?', params['entry_id']).first
    raise Isucon5::ContentNotFound unless entry
    entry[:title], entry[:content] = entry[:body].split(/\n/, 2)
    entry[:is_private] = (entry[:private] == 1)
    owner = get_user(entry[:user_id])
    if entry[:is_private] && !permitted?(owner[:id])
      raise Isucon5::PermissionDenied
    end
    comments = db.xquery('SELECT * FROM comments WHERE entry_id = ?', entry[:id])
    mark_footprint(owner[:id])
    erb :entry, locals: { owner: owner, entry: entry, comments: comments }
  end

  post '/diary/entry' do
    authenticated!
    query = 'INSERT INTO entries (user_id, private, body) VALUES (?,?,?)'
    body = (params['title'] || "タイトルなし") + "\n" + params['content']
    db.xquery(query, current_user[:id], (params['private'] ? '1' : '0'), body)
    redirect "/diary/entries/#{current_user[:account_name]}"
  end

  post '/diary/comment/:entry_id' do
    authenticated!
    entry = db.xquery('SELECT id,private,user_id FROM entries WHERE id = ?', params['entry_id']).first
    unless entry
      raise Isucon5::ContentNotFound
    end
    entry[:is_private] = (entry[:private] == 1)
    if entry[:is_private] && !permitted?(entry[:user_id])
      raise Isucon5::PermissionDenied
    end
    query = 'INSERT INTO comments (entry_id, user_id, comment) VALUES (?,?,?)'
    db.xquery(query, entry[:id], current_user[:id], params['comment'])
    redirect "/diary/entry/#{entry[:id]}"
  end

  get '/footprints' do
    authenticated!
    query = <<SQL
SELECT user_id, owner_id, DATE(created_at) AS date, MAX(created_at) as updated
FROM footprints
WHERE user_id = ?
GROUP BY user_id, owner_id, DATE(created_at)
ORDER BY updated DESC
LIMIT 50
SQL
    footprints = db.xquery(query, current_user[:id])
    erb :footprints, locals: { footprints: footprints }
  end

  get '/friends' do
    authenticated!

    # current_user の友だちリスト
    list = friends(current_user[:id]).map {|user_id| [user_id, Time.now]}
    erb :friends, locals: { friends: list }
  end

  post '/friends/:account_name' do
    authenticated!
    unless is_friend_account?(params['account_name'])
      user = user_from_account(params['account_name'])
      unless user
        raise Isucon5::ContentNotFound
      end

      # redis.lrange("friend:#{user_id}", 0, -1)
      redis.rpush "friend:#{current_user[:id]}", user[:id]
      redis.rpush "friend:#{user[:id]}", current_user[:id]
      redirect '/friends'
    end
  end

  get '/initialize' do
#    db.query("DELETE FROM relations WHERE id > 500000")
    system '/home/isucon/initialize.sh'
    db.query("DELETE FROM footprints WHERE id > 500000")
    db.query("DELETE FROM entries WHERE id > 500000")
    db.query("DELETE FROM comments WHERE id > 1500000")
  end
end

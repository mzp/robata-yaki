# ISUCON 虎の巻

## リンク集
* [ISUCON55 予選レギュレーション](http://isucon.net/archives/45347574.html)
  * ベンチマーク実行時にアプリケーションに書き込まれたデータは再起動後にも取得できること (重要)
  * レスポンスHTMLのDOM構造が変化していないこと (重要)
* [ISUCON5 予選ポータルサイト](http://isucon5q.tagomor.is/)

## 計測

### Apache

```
# %D を追加
$ vim httpd.conf
LogFormat "%h %l %u %t "%r" %>s %b "%{Referer}i" "% {User-Agent}i" "%v" "%{cookie}n" %D" combined
$ rm /var/log/httpd/access_log
$ service httpd restart
# ベンチマーク実行
$ cat access_log | analyze_apache_logs
```

### nginx + visitors
```
$ cd /usr/local/src
$ wget http://www.hping.org/visitors/$ visitors-0.7.tar.gz
$ tar zxvf visitors-0.7.tar.gz
$ make

$ ./visitors -A -o text /var/log/nginx/access_log

* Different pages requested: 4
1)    /: 4160
2)    /login: 2284
3)    /mypage: 440
4)    /report: 6
```

### SQL
```
# mysqlのコンソールにて
> set global slow_query_log = 1;
> set global long_query_time = 0;
> set global slow_query_log_file = "/tmp/slow.log";
# ベンチマーク実行
$ mysqldumpslow -s t /tmp/slow.log > /tmp/digest.txt
$ rm /tmp/slow.log
# 戻すときは
$ service mysqld restart
```

### Ruby
stackprof.gem 使う

```
$ cat Gemfile
gem 'stackprof'
$ bundle install
```

```
$ vim app.rb
StackProf.run(mode: :cpu, out: 'tmp/stackprof-cpu-sample.dump') do
  # main process
end
```

または

```
$ vim config.ru
require 'stackprof' #if ENV['ISUPROFILE']
Dir.mkdir('/tmp/stackprof') unless File.exist?('/tmp/stackprof')
use StackProf::Middleware, enabled: ENV['ISUPROFILE'] == ?1, mode: :wall, interval: 500, save_every: 100, path: '/tmp/stackprof'
```

```
$ bundle exec stackprof tmp/stackprof-cpu-sample.dump
```

## サーバ負荷
* top
* iftop
* iotop
* dstat

## OS

#### TCP の最適化
ベンチマークツールの http keepalive が無効なので、sysctrl.conf で ephemeral port を拡大したり、TIME_WAIT が早く回収されるように変更する

```
$ cat /etc/sysctl.conf
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.ip_local_port_range = 10000 65000
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
```
適用

```
$ sudo /sbin/sysctl -p
```

### TCP Fast Open
```
sudo sh -c "echo 0x707 > /proc/sys/net/ipv4/tcp_fastopen"
```
よくわからないので奥の手。

## ミドルウェア
### nginx

速そうな設定

```
$ cat /etc/nginx/nginx.conf
worker_processes  1; # 要調整

events {
  worker_connections  10000; # 要調整
  multi_accept on;
  use epoll;
}

http {
  include     mime.types;
  access_log  off;
  sendfile    on;
  tcp_nopush  on;
  tcp_nodelay on;
  etag        off;
  gzip        off; # 要調整
  server_tokens   off;

  include /etc/nginx/mime.types;
}
```

UNIX domain socket を使うように変更する(アプリ側もやる)

```
$ cat /etc/nginx/nginx.conf
http {
  upstream app {
    server unix:/dev/shm/app.sock fail_timeout=0;
  }
}
```

### 速度に関係しそうな設定
* worker_proces
* worker_connection
* gzip
* epol
* sendfile
* keepalive off
* worker_rlimit_nofile

## DB
### mysql の設定
```
$ cat /etc/my.cnf
max_allowed_packet=300M # 要調整
innodb_buffer_pool_size = 1G # 要調整
innodb_flush_log_at_trx_commit = 0
innodb_flush_method=O_DIRECT
```
```
sudo service mysqld restart
```

### UNIX domain socket を使うように変更する
```
$ cat /etc/my.conf
[mysqld]
socket=/var/lib/mysql/mysql.sock
symbolic-links=0
```

### インデックスを張る
```
$ cat init.sh 
cat <<'EOF' | mysql -h ${myhost} -P ${myport} -u ${myuser} ${mydb}
alter table login_log add index ip (ip), add index user_id (user_id);
EOF
```

## Unicorn
env.sh に以下を追加

```
export RACK_ENV=production 
```

unicorn_config を以下のように変更

```
worker_processes 4 # 要調整
preload_app true
listen "/dev/shm/app.sock"
```

Procfile を以下のように変更

```
unicorn: bundle exec unicorn -c unicorn_config.rb -l /dev/shm/app.sock
```

## Redis
Unix domain socket 使う

```
$ cat /etc/redis.conf
unixsocket /tmp/redis.sock
unixsocketperm 700
```

```ruby
redis = Redis.new(:path => "/tmp/redis.sock")
```

## アプリ
### 静的ファイルを nginx にホスティングさせる

```
$ cat /etc/nginx/nginx.conf
http {
    server {
        location ~ ^/assets/ {
            open_file_cache max=100;
            root   /home/myproj/release/current/public;
        }
    }
}
```

### 1+n 問題を修正する
### MySQL やめて Redis にする
### 重い処理を消す
* 外部プロセスの起動
* HTML テンプレート処理
* テキスト / 画像変換処理
* RDBMS / Cache との接続回数減らす
* 1+N 問題

### Sinatra を production モードにする
```
$ vim app.rb
require 'sinatra'
class App < Sinatra::Base
  set :environment, :production
end
```

```RACK_ENV=production``` があればいらないかも

### erb が遅いので erubis にする

```
$ vim Gemfile
gem 'erubis'
```
### OobGC を使う
```
$ vim Gemfile
gem 'gctools'
```
```
$ vim config.ru
require 'gctools/oobgc'
if defined?(Unicorn::HttpRequest)
  use GC::OOB::UnicornMiddleware
end
```

### Redis の接続を hiredis にする
### Sinatra やめて Rack アプリにする
### link タグと img タグをdocument.writeで書きだす
### Redis すらやめてソースコードにベタ書きする
### Ruby のバージョン上げる
### HTML minify


## その他
### ベンチマークのオプションをいろいろ試す
どうせ GO なので

* GOGC=off
* GOMAXPROCS=8 (デフォルトは4)

と思ったけど今回 GCP なので、リモートベンチかも。

workload の数値をめっちゃ上げる。

### tmpfs 芸
でも MySQL や Redis の永続化データは移動しちゃダメ。
レギュレーションにひっかかるので。
逆に起動時と終了時に rsync 使って、同期するとスコアが伸びるという話も。

### too many open files 対策
```
$ sudo vim /etc/sysctl.conf
fs.file-max=320000
$ sudo vim /etc/security/limits.conf 
* hard nofile 65535
* soft nofile 65535
```

### access_log 切る
### iptables 切る
### Unicorn やめて Rhebok にする
[Unicornの2倍のパフォーマンスを実現したRackサーバ「Rhebok」をリリースしました](http://blog.nomadscafe.jp/2014/12/rhebok-high-performance-rack-server.html)

## 参考 URL
* [ISUCON4 予選でアプリケーションを変更せずに予選通過ラインを突破するの術](http://kazeburo.hatenablog.com/entry/2014/10/14/170129)
* [MySQLでのSlowLogの分析方法](http://qiita.com/tamano/items/50c7d7ee08b133a18b97)
* [Isucon4 本戦に参加して17位でした (GoMiami)](http://blog.livedoor.jp/sonots/archives/41497394.html)
* [nginx で Too many open files エラーに対処する](http://www.1x1.jp/blog/2013/02/nginx_too_many_open_files_error.html)
* [stackprofを使ってみる](http://spring-mt.hatenablog.com/entry/2014/09/21/014930)
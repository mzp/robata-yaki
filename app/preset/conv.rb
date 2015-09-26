#   `id` int(11) NOT NULL AUTO_INCREMENT,
#  `account_name` varchar(64) NOT NULL,
#  `nick_name` varchar(32) NOT NULL,
#  `email` varchar(255) CHARACTER SET utf8 NOT NULL,
#  `passhash` varchar(128) NOT NULL,
require 'pp'
user_from_id = {}
user_from_account = {}

ARGF.each do |line|
  id,account_name, nick_name, email, passhash = line.chomp.split "\t"

  hash = {
    id: id.to_i, account_name: account_name, nick_name: nick_name, email: email, passhash: passhash
  }

  user_from_id[id] = hash
  user_from_account[account_name] = hash
end

puts <<END
$user_from_id = #{user_from_id.inspect}

$user_from_account = #{user_from_account.inspect}
END

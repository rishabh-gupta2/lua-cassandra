# vim:set ts=4 sw=4 et fdm=marker:
use Test::Nginx::Socket::Lua;

our $HttpConfig = <<_EOC_;
    lua_package_path 'lib/?.lua;lib/?/init.lua;;';
    lua_shared_dict cassandra 1m;
    lua_socket_log_errors off;
_EOC_

plan tests => repeat_each() * blocks() * 3;

run_tests();

__DATA__

=== TEST 1: cluster.new() invalid opts
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local Cluster = require 'resty.cassandra.cluster'
            local cluster, err = Cluster.new('')
            if not cluster then
                ngx.say(err)
            end

            cluster, err = Cluster.new({shm = true})
            if not cluster then
                ngx.say(err)
            end

            cluster, err = Cluster.new({shm = 'invalid_shm'})
            if not cluster then
                ngx.say(err)
            end
        }
    }
--- request
GET /t
--- response_body
opts must be a table
shm must be a string
no shared dict invalid_shm
--- no_error_log
[error]



=== TEST 2: cluster.new() default opts
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local Cluster = require 'resty.cassandra.cluster'
            local cluster, err = Cluster.new()
            if not cluster then
                ngx.log(ngx.ERR, err)
                return
            end
        }
    }
--- request
GET /t
--- response_body

--- no_error_log
[error]



=== TEST 3: cluster.new() retry_on_timeout opts
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local Cluster = require 'resty.cassandra.cluster'
            local cluster, err = Cluster.new()
            if not cluster then
                ngx.log(ngx.ERR, err)
                return
            end
            ngx.say('default: ', cluster.retry_on_timeout)

            cluster, err = Cluster.new({retry_on_timeout = false})
            if not cluster then
                ngx.log(ngx.ERR, err)
                return
            end
            ngx.say('false opt: ', cluster.retry_on_timeout)

            cluster, err = Cluster.new({retry_on_timeout = true})
            if not cluster then
                ngx.log(ngx.ERR, err)
                return
            end
            ngx.say('true opt: ', cluster.retry_on_timeout)
        }
    }
--- request
GET /t
--- response_body
default: true
false opt: false
true opt: true
--- no_error_log
[error]



=== TEST 4: cluster.refresh() with invalid contact_points
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local Cluster = require 'resty.cassandra.cluster'
            local cluster, err = Cluster.new {
                contact_points = {'127.0.0.255'},
                connect_timeout = 10
            }
            if not cluster then
                ngx.log(ngx.ERR, err)
            end

            local ok, err = cluster:refresh()
            ngx.say(ok)
            ngx.say(err)
        }
    }
--- request
GET /t
--- response_body
nil
all hosts tried for query failed. 127.0.0.255: host seems unhealthy, considering it down (timeout)
--- no_error_log
[error]



=== TEST 5: cluster.refresh() sets hosts in shm
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local Cluster = require 'resty.cassandra.cluster'
            local cluster, err = Cluster.new()
            if not cluster then
                ngx.log(ngx.ERR, 'could not spawn cluster: ', err)
            end

            local ok, err = cluster:refresh()
            if not ok then
                ngx.log(ngx.ERR, 'could not refresh: ', err)
            end

            local peers, err = cluster:get_shm_peers()
            if not peers then
                ngx.log(ngx.ERR, 'could not get shm peers: ', err)
            end

            for i = 1, #peers do
                local p = peers[i]
                local up = ngx.shared.cassandra:get(p.host)
                ngx.say(p.host..' '..p.unhealthy_at..' '..p.reconn_delay, ' ', up)
            end
        }
    }
--- request
GET /t
--- response_body
127.0.0.3 0 0 true
127.0.0.2 0 0 true
127.0.0.1 0 0 true
--- no_error_log
[error]



=== TEST 6: cluster.refresh() inits cluster
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local Cluster = require 'resty.cassandra.cluster'
            local cluster, err = Cluster.new()
            if not cluster then
                ngx.log(ngx.ERR, 'could not spawn cluster: ', err)
            end

            if cluster.init then
                ngx.log(ngx.ERR, 'cluster already init')
            end

            local ok, err = cluster:refresh()
            if not ok then
                ngx.log(ngx.ERR, 'could not refresh: ', err)
            end

            ngx.say('init: ', cluster.init)
        }
    }
--- request
GET /t
--- response_body
init: true
--- no_error_log
[error]



=== TEST 7: cluster.refresh() removes old peers
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local Cluster = require 'resty.cassandra.cluster'
            local cluster, err = Cluster.new()
            if not cluster then
                ngx.log(ngx.ERR, err)
            end

            -- insert fake peers
            cluster:set_shm_peer('127.0.0.253', 0, 0)
            cluster:set_shm_peer('127.0.0.254', 0, 0)

            local ok, err = cluster:refresh()
            if not ok then
                ngx.log(ngx.ERR, err)
            end

            local peers, err = cluster:get_shm_peers()
            if not peers then
                ngx.log(ngx.ERR, err)
            end

            for i = 1, #peers do
                ngx.say(peers[i].host)
            end
        }
    }
--- request
GET /t
--- response_body
127.0.0.3
127.0.0.2
127.0.0.1
--- no_error_log
[error]



=== TEST 8: get_peers() corrupted shm
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local Cluster = require 'resty.cassandra.cluster'
            local cluster, err = Cluster.new()
            if not cluster then
                ngx.log(ngx.ERR, err)
            end

            cluster.shm:set('host:rec:127.0.0.1', 'foobar')

            local peers, err = cluster:get_shm_peers()
            if not peers then
                ngx.log(ngx.ERR, err)
            end
        }
    }
--- request
GET /t
--- response_body

--- error_log
corrupted shm



=== TEST 9: set_peer_down()/set_peer_up()/can_try_peer() set shm booleans for nodes health
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local Cluster = require 'resty.cassandra.cluster'
            local cluster, err = Cluster.new()
            if not cluster then
                ngx.log(ngx.ERR, err)
            end

            local ok, err = cluster:refresh()
            if not ok then
                ngx.log(ngx.ERR, err)
            end

            local peers, err = cluster:get_shm_peers()
            if not peers then
                ngx.log(ngx.ERR, err)
            end

            for i = 1, #peers do
                ok = cluster:can_try_peer(peers[i].host)
                ngx.say(peers[i].host, ' default: ', ok)

                ok, err = cluster:set_peer_down(peers[i].host)
                if not ok then
                    ngx.log(ngx.ERR, err)
                    return
                end

                ok = cluster:can_try_peer(peers[i].host)
                ngx.say(peers[i].host, ' after down: ', ok)

                ok, err = cluster:set_peer_up(peers[i].host)
                if not ok then
                    ngx.log(ngx.ERR, err)
                    return
                end

                ok = cluster:can_try_peer(peers[i].host)
                ngx.say(peers[i].host, ' after up: ', ok)
            end
        }
    }
--- request
GET /t
--- response_body
127.0.0.3 default: true
127.0.0.3 after down: false
127.0.0.3 after up: true
127.0.0.2 default: true
127.0.0.2 after down: false
127.0.0.2 after up: true
127.0.0.1 default: true
127.0.0.1 after down: false
127.0.0.1 after up: true
--- no_error_log
[error]



=== TEST 10: set_peer_down()/set_peer_up() use reconnection policy (update peer_rec delays)
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
         local Cluster = require 'resty.cassandra.cluster'
            local cluster, err = Cluster.new()
            if not cluster then
                ngx.log(ngx.ERR, err)
                return
            end

            local delay = cluster.reconn_policy:next_delay('foo')

            local ok, err = cluster:refresh()
            if not ok then
                ngx.log(ngx.ERR, err)
                return
            end

            ok, err = cluster:set_peer_down('127.0.0.1')
            if not ok then
                ngx.log(ngx.ERR, err)
                return
            end

            local peer_rec, err = cluster:get_shm_peer('127.0.0.1')
            if not peer_rec then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say('down')
            ngx.say('unhealthy_at: ', peer_rec.unhealthy_at > 0)
            ngx.say('reconn_delay: ', peer_rec.reconn_delay == delay)

            local ok, err = cluster:set_peer_up('127.0.0.1')
            if not ok then
                ngx.log(ngx.ERR, err)
                return
            end

            peer_rec, err = cluster:get_shm_peer('127.0.0.1')
            if not peer_rec then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say('up')
            ngx.say('unhealthy_at: ', peer_rec.unhealthy_at)
            ngx.say('reconn_delay: ', peer_rec.reconn_delay)

            ok, err = cluster:set_peer_down('127.0.0.1')
            if not ok then
                ngx.log(ngx.ERR, err)
                return
            end

            peer_rec, err = cluster:get_shm_peer('127.0.0.1')
            if not peer_rec then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say('down again')
            ngx.say('unhealthy_at: ', peer_rec.unhealthy_at > 0)
            ngx.say('reconn_delay: ', peer_rec.reconn_delay == delay)
        }
    }
--- request
GET /t
--- response_body
down
unhealthy_at: true
reconn_delay: true
up
unhealthy_at: 0
reconn_delay: 0
down again
unhealthy_at: true
reconn_delay: true
--- no_error_log
[error]



=== TEST 11: can_try_peer() use reconnection policy to decide when node is down
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local Cluster = require 'resty.cassandra.cluster'
            local cluster, err = Cluster.new()
            if not cluster then
                ngx.log(ngx.ERR, err)
                return
            end

            local ok, err = cluster:refresh()
            if not ok then
                ngx.log(ngx.ERR, err)
                return
            end

            local ok, err, is_retry = cluster:can_try_peer('127.0.0.1')
            if err then
                ngx.log(ngx.ERR, err)
                return
            end
            ngx.say('before down: ', ok, ' ', is_retry)

            ok, err = cluster:set_peer_down('127.0.0.1')
            if not ok then
                ngx.log(ngx.ERR, err)
                return
            end

            ok, err, is_retry = cluster:can_try_peer('127.0.0.1')
            if err then
                ngx.log(ngx.ERR, err)
                return
            end
            ngx.say('until delay: ', ok, ' ', is_retry)

            ok, err = cluster:set_shm_peer('127.0.0.1', 1000, 1460780710809)
            if not ok then
                ngx.log(ngx.ERR, 'could not set peer_rec: ', err)
                return
            end

            ok, err, is_retry = cluster:can_try_peer('127.0.0.1')
            if err then
                ngx.log(ngx.ERR, err)
                return
            end
            ngx.say('after delay: ', ok, ' ', is_retry)
        }
    }
--- request
GET /t
--- response_body
before down: true nil
until delay: false true
after delay: true true
--- no_error_log
[error]



=== TEST 12: next_coordinator() uses load balancing policy
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local Cluster = require 'resty.cassandra.cluster'
            local cluster, err = Cluster.new()
            if not cluster then
                ngx.log(ngx.ERR, err)
            end

            local ok, err = cluster:refresh()
            if not ok then
                ngx.log(ngx.ERR, err)
            end

            local coordinator = cluster:next_coordinator()
            ngx.say('coordinator 1: ', coordinator.host)

            coordinator = cluster:next_coordinator()
            ngx.say('coordinator 2: ', coordinator.host)

            coordinator = cluster:next_coordinator()
            ngx.say('coordinator 3: ', coordinator.host)
        }
    }
--- request
GET /t
--- response_body
coordinator 1: 127.0.0.3
coordinator 2: 127.0.0.2
coordinator 3: 127.0.0.1
--- no_error_log
[error]



=== TEST 13: next_coordinator() returns no host available errors
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local Cluster = require 'resty.cassandra.cluster'
            local cluster, err = Cluster.new()
            if not cluster then
                ngx.log(ngx.ERR, err)
            end

            local ok, err = cluster:refresh()
            if not ok then
                ngx.log(ngx.ERR, err)
            end

            local peers, err = cluster:get_shm_peers()
            if not peers then
                ngx.log(ngx.ERR, err)
            end

            for i = 1, #peers do
                local ok, err = cluster:set_peer_down(peers[i].host)
                if not ok then
                    ngx.log(ngx.ERR, err)
                    return
                end
            end

            local coordinator, err = cluster:next_coordinator()
            if not coordinator then
                ngx.say(err)
            end
        }
    }
--- request
GET /t
--- response_body
all hosts tried for query failed. 127.0.0.2: host still considered down. 127.0.0.3: host still considered down. 127.0.0.1: host still considered down
--- no_error_log
[error]



=== TEST 14: next_coordinator() avoids down hosts
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local Cluster = require 'resty.cassandra.cluster'
            local cluster, err = Cluster.new()
            if not cluster then
                ngx.log(ngx.ERR, err)
            end

            local ok, err = cluster:refresh()
            if not ok then
                ngx.log(ngx.ERR, err)
            end

            local ok, err = cluster:set_peer_down('127.0.0.1')
            if not ok then
                ngx.log(ngx.ERR, err)
                return
            end

            for i = 1, 5 do
                local coordinator, err = cluster:next_coordinator()
                if not coordinator then
                    ngx.say(err)
                end
                ngx.say(i, ' ', coordinator.host)
            end
        }
    }
--- request
GET /t
--- response_body
1 127.0.0.3
2 127.0.0.2
3 127.0.0.3
4 127.0.0.3
5 127.0.0.2
--- no_error_log
[error]



=== TEST 15: next_coordinator() marks nodes as down
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local Cluster = require 'resty.cassandra.cluster'
            local cluster, err = Cluster.new {
                timeout_connect = 100
            }
            if not cluster then
                ngx.log(ngx.ERR, err)
            end

            -- insert fake nodes
            local ok, err = cluster:set_peer_up('127.0.0.8')
            if not ok then
                ngx.log(ngx.ERR, err)
                return
            end
            ok, err = cluster:set_peer_up('127.0.0.9')
            if not ok then
                ngx.log(ngx.ERR, err)
                return
            end

            local peers, err = cluster:get_shm_peers()
            if not peers then
                ngx.log(ngx.ERR, err)
                return
            end

            -- init cluster as if it was refreshed
            cluster.lb_policy:init(peers)
            cluster.init = true

            -- attempt to get next coordinator
            local coordinator, err = cluster:next_coordinator()
            if not coordinator then
                ngx.say('all down: ', err)
            end

            -- verify they were marked down
            for i = 1, #peers do
                local ok, err = cluster:can_try_peer(peers[i].host)
                if err then
                    ngx.log(ngx.ERR, err)
                    return
                end

                ngx.say('can try peer ', peers[i].host, ': ', ok)
            end
        }
    }
--- request
GET /t
--- response_body
all down: all hosts tried for query failed. 127.0.0.8: host seems unhealthy, considering it down (timeout). 127.0.0.9: host seems unhealthy, considering it down (timeout)
can try peer 127.0.0.8: false
can try peer 127.0.0.9: false
--- no_error_log
[error]



=== TEST 16: next_coordinator() retries down host as per reconnection policy and ups them back
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local Cluster = require 'resty.cassandra.cluster'
            local cluster, err = Cluster.new {
                timeout_connect = 100
            }
            if not cluster then
                ngx.log(ngx.ERR, err)
            end

            local ok, err = cluster:refresh()
            if not ok then
                ngx.log(ngx.ERR, err)
            end

            local peers, err = cluster:get_shm_peers()
            if not peers then
                ngx.log(ngx.ERR, err)
                return
            end

            -- mark all nodes as down
            for i = 1, #peers do
                local ok, err = cluster:set_peer_down(peers[i].host)
                if not ok then
                    ngx.log(ngx.ERR, err)
                    return
                end

                -- simulate delay for retry from reconnection policy
                ok, err = cluster:set_shm_peer(peers[i].host, 1000, 1460780710809)
                if not ok then
                    ngx.log(ngx.ERR, 'could not set peer_rec: ', err)
                    return
                end
            end

            -- try to get some coordinators
            for i = 1, #peers do
                local coordinator, err = cluster:next_coordinator()
                if not coordinator then
                    ngx.log(ngx.ERR, 'could not get coordinator: ', err)
                    return
                end
            end

            for i = 1, #peers do
                local ok, err = cluster:can_try_peer(peers[i].host)
                if not ok then
                     ngx.log(ngx.ERR, peers[i].host..': ', err)
                end
                ngx.say(peers[i].host .. ' is back up: ', ok)
            end
        }
    }
--- request
GET /t
--- response_body
127.0.0.3 is back up: true
127.0.0.2 is back up: true
127.0.0.1 is back up: true
--- no_error_log
[error]

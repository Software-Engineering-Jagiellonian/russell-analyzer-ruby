#!/usr/bin/env ruby
# encoding: utf-8

require "rubygems"
require "bunny"
require "json"
require "tmpdir"
require 'logger'
require 'active_record'
require 'fileutils'

require "./models"
require "./metrics/flog"
require "./metrics/rubycritic"
require "./metrics/cycromatic"

$logging = Logger.new(STDOUT)

REPOSITORIES_DIR = "/repositories/"

class FileNotFound < StandardError; end

# Configure ActiveRecord connection
ActiveRecord::Base.establish_connection(
  adapter: 'postgresql',
  host: ENV['DB_HOST'],
  post: ENV['DB_PORT'],
  username: ENV['DB_USERNAME'],
  password: ENV['DB_PASSWORD'],
  database: ENV['DB_DATABASE']
)


def analyze_repo(repo_id)
    repo_path = File.join(REPOSITORIES_DIR, repo_id)

    unless File.directory?(repo_path)
        $logging.warn("Repository download dir not found: '#{repo_path}'")
        raise(FileNotFound, "File #{repo_path} not found")
    end

    $logging.info("Collecting metrics for '#{repo_id}'")
    metrics = {
        flog: MetricFlog.analyze(repo_path),
        rubycritic: MetricRubyCritic.analyze(repo_path),
        cycromatic: MetricCycromatic.analyze(repo_path)
    }
    $logging.debug("Collected metrics: #{metrics}")

    # Save metrics to DB
    RubyMetric.upsert(
        repo_id: repo_id,
        metrics: metrics
    )
    return true
end



STDOUT.sync = true
WAIT_TIME = 1

conn = Bunny.new(hostname: ENV['RMQ_HOST'], port: ENV['RMQ_PORT'])

conn.start

ch = conn.create_channel
q  = ch.queue("analyze-ruby", :durable => true)#, :auto_delete => true)
x  = ch.default_exchange


$logging.info("Starting message loop")

loop do 
    # pop single message from RabbitMQ
    sleep WAIT_TIME
    delivery_info, metadata, payload = q.pop(manual_ack: true)
    next if payload == nil

    begin
        payload = JSON.parse(payload)
        $logging.debug "Message Received: #{payload}"

        raise "Metric calculation Error" unless analyze_repo(payload["repo_id"])

        ch.ack(delivery_info.delivery_tag)
        x.publish({
            repo_id: payload["repo_id"],
            language_id: RUBY_LANGAUGE_ID
        }.to_json, routing_key: "gc")
        $logging.info("Completed request: #{payload}")
    rescue JSON::ParserError
        # Message is not correct JSON, we can't parse it, we reject it!
        $logging.warn("Rejecting malformed message: #{payload}")
        ch.nack(delivery_info.delivery_tag, requeue: false)
    rescue FileNotFound => e
        $logging.warn("FileNotFound: #{e}")
        ch.nack(delivery_info.delivery_tag, requeue: false)
    rescue Exception => e
        ch.reject(delivery_info.delivery_tag, requeue: true)
        raise
    end
end

conn.close

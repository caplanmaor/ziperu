# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "json"
require "ziperu/rails_streaming"

# Every Ruby example in README.md, run as written. Each block runs in a
# directory of its own holding the files the examples name (archive.zip,
# secret.zip, public/ ...), with the free variables they use (`csv`,
# `socket`, `params` ...) defined. The only rewrites: a `{ |x| ... }`
# placeholder body becomes empty, and the one absolute path is made
# relative. A README example that stops working fails here.
class ReadmeTest < Minitest::Test
  include TestHelper

  README = File.expand_path("../README.md", __dir__)

  # The blocks, as [line number, code]. The Gemfile snippet is not Ruby
  # to run.
  def self.blocks
    lines = File.readlines(README)
    blocks = []
    start = nil
    lines.each_with_index do |line, i|
      if start.nil? && line.start_with?("```ruby")
        start = i + 1
      elsif start && line.start_with?("```")
        code = lines[start...i].join
        blocks << [start + 1, code] unless code.strip.start_with?("gem ")
        start = nil
      end
    end
    blocks
  end

  # What the examples refer to without defining.
  class Context
    Attachment = Struct.new(:filename, :data) do
      def download
        data.each_slice(3) { |chunk| yield chunk.join }
      end
    end

    # A minimal stand-in for ActionController::Base: a headers Hash and a
    # body, which is all RailsStreaming touches.
    class ApplicationController
      Response = Struct.new(:headers)
      attr_accessor :response_body

      def response
        @response ||= Response.new({})
      end

      # The app's own data, which the example's action writes.
      def csv
        "id
1
"
      end
    end

    attr_reader :processed

    def initialize(dir)
      @dir = dir
      @processed = []
    end

    def csv
      "id,name\n1,one\n2,two\n"
    end

    def bytes
      @bytes ||= Random.new(1).bytes(4096)
    end

    # A seekable IO holding an archive: what the examples write to and
    # read from as "socket".
    def socket
      @socket ||= StringIO.new(File.binread(File.join(@dir, "archive.zip")))
    end

    def params
      { upload: File.open(File.join(@dir, "archive.zip"), "rb") }
    end

    def upload
      File.join(@dir, "archive.zip")
    end

    def manifest
      { "files" => 2 }
    end

    def attachments
      [Attachment.new("a.txt", %w[a b c d]), Attachment.new("b.txt", %w[e f])]
    end

    def process(name, data)
      @processed << [name, data]
    end

    def run(code, line)
      instance_eval(code, README, line)
    end
  end

  def setup
    Ziperu.reset!
    @dir = Dir.mktmpdir("ziperu-readme")
    fixtures
  end

  def teardown
    Ziperu.reset!
    FileUtils.rm_rf(@dir)
  end

  blocks.each do |line, code|
    define_method("test_readme_block_at_line_#{line}") do
      code = code.gsub(/\{ \|(\w+)\| \.\.\. \}/) { "{ |#{Regexp.last_match(1)}| }" }
                 .gsub('"/var/log/', '"var/log/')
      ctx = Context.new(@dir)
      result = nil
      Dir.chdir(@dir) { capture_io { result = ctx.run(code, line) } }
      check_result(result)
      check_controller(ctx)
      check_archives
    end
  end

  private

  def fixtures
    Dir.chdir(@dir) do
      Ziperu::OutputStream.open("archive.zip") do |z|
        z.put_next_entry("README.txt")
        z.write("read me\n")
        z.put_next_entry("docs/guide.txt")
        z.write("a guide\n")
      end
      FileUtils.mkdir_p("tmp")
      File.binwrite("tmp/report.pdf", "%PDF-1.4 not really\n")
      Ziperu::OutputStream.open("huge.zip") do |z|
        z.put_next_entry("data.bin")
        z.write("x" * 100)
        z.put_next_entry("data.bin.sig")
        z.write("signature")
      end
      Ziperu::OutputStream.open("secret.zip", encrypter: Ziperu::AESEncrypter.new("s3cret")) do |z|
        z.put_next_entry("plan.txt")
        z.write("the plan")
      end
      FileUtils.mkdir_p("public/css")
      File.write("public/index.html", "<p>hi</p>")
      File.write("public/css/site.css", "p{}")
      File.write("public/debug.log", "noise")
      Ziperu::OutputStream.open("backup.zip") do |z|
        z.put_next_entry("old.log")
        z.write("old")
        z.put_next_entry("manifest.json")
        z.write("{}")
      end
      FileUtils.mkdir_p("var/log/app")
      File.write("var/log/app/today.log", "today")
    end
  end

  # A Rack response triple's body is consumed, and must be an archive.
  def check_result(result)
    return unless result.is_a?(Array) && result.size == 3 && result[2].respond_to?(:each)

    assert_equal 200, result[0]
    bytes = result[2].to_a.join
    Ziperu::File.open_buffer(bytes) do |zf|
      refute_empty zf.entries
      assert_empty zf.verify
    end
  end

  # A controller the block defined is asked for its action.
  def check_controller(ctx)
    klass = ctx.singleton_class.const_get(:ExportsController, false) if
      ctx.singleton_class.const_defined?(:ExportsController, false)
    return unless klass

    controller = klass.new
    controller.show
    assert_match(/attachment; filename="export.zip"/, controller.response.headers["content-disposition"])
    Ziperu::File.open_buffer(controller.response_body.to_a.join) { |zf| assert_equal ["a.csv"], zf.entries.map(&:name) }
  end

  # Whatever archives the block left behind are readable.
  def check_archives
    Dir.glob(File.join(@dir, "*.zip")).each do |path|
      Ziperu::File.open(path, password: "s3cret") { |zf| assert_empty zf.verify, File.basename(path) }
    end
  end
end

# frozen_string_literal: true

# rubyzip as a second oracle for fuzz/differential.rb, run in its own
# process with rubyzip's lib on the load path:
#
#   ruby -I tmp/rubyzip/lib fuzz/rubyzip_oracle.rb write SPEC.json OUT.zip
#   ruby -I tmp/rubyzip/lib fuzz/rubyzip_oracle.rb read  IN.zip   OUT.json [PASSWORD aes|traditional]
#
# Same JSON shapes as oracle.py, plus "password" and "encryption"
# ("aes" | "traditional") on a write spec, which Python cannot produce.

require 'zip'
require 'json'
require 'base64'

raise 'this must run against rubyzip, not ziperu' if defined?(Ziperu) && Zip.equal?(Ziperu)

METHODS = { 'stored' => Zip::Entry::STORED, 'deflated' => Zip::Entry::DEFLATED }.freeze

def encrypter_for(spec)
  password = spec['password'] or return nil
  case spec['encryption']
  when 'aes' then Zip::AESEncrypter.new(password, Zip::AESEncryption::STRENGTH_256_BIT)
  when 'traditional' then Zip::TraditionalEncrypter.new(password)
  end
end

def write(spec_path, out_path)
  spec = JSON.parse(File.read(spec_path))
  Zip::OutputStream.open(out_path, encrypter: encrypter_for(spec)) do |zos|
    zos.comment = spec['comment'] if spec['comment'] && !spec['comment'].empty?
    spec['entries'].each do |e|
      name = e['name']
      name = "#{name}/" if e['dir'] && !name.end_with?('/')
      entry = Zip::Entry.new('', name, comment: e['comment'].to_s,
                                       compression_method: METHODS.fetch(e['method'] || 'deflated'))
      entry.time = Zip::DOSTime.new(*e['mtime']) if e['mtime']
      zos.put_next_entry(entry, nil, nil, entry.compression_method, spec['level'] || Zlib::DEFAULT_COMPRESSION)
      zos.write(Base64.decode64(e['data'])) unless e['dir']
    end
  end
end

def decrypter_for(password, encryption)
  return nil unless password

  case encryption
  when 'aes' then Zip::AESDecrypter.new(password, Zip::AESEncryption::STRENGTH_256_BIT)
  else Zip::TraditionalDecrypter.new(password)
  end
end

def read(in_path, out_path, password, encryption)
  decrypter = decrypter_for(password, encryption)
  result = { 'ok' => true, 'error' => nil, 'comment' => '', 'entries' => [] }
  begin
    Zip::File.open(in_path) do |zf|
      result['comment'] = zf.comment.to_s
      zf.entries.each do |entry|
        record = {
          'name' => entry.name, 'size' => entry.size, 'compress_size' => entry.compressed_size,
          'crc' => entry.crc, 'method' => METHODS.key(entry.compression_method) || entry.compression_method.to_s,
          'dir' => entry.directory?, 'comment' => entry.comment.to_s
        }
        begin
          data = entry.directory? ? '' : entry.get_input_stream(decrypter: decrypter, &:read)
          record['data'] = Base64.strict_encode64(data)
        rescue StandardError => e
          record['error'] = "#{e.class}: #{e.message}"
        end
        result['entries'] << record
      end
    end
  rescue StandardError => e
    result['ok'] = false
    result['error'] = "#{e.class}: #{e.message}"
  end
  File.write(out_path, JSON.generate(result))
end

case ARGV[0]
when 'write' then write(ARGV[1], ARGV[2])
when 'read' then read(ARGV[1], ARGV[2], ARGV[3], ARGV[4])
else abort 'usage: rubyzip_oracle.rb write SPEC OUT | read IN OUT [PASSWORD ENCRYPTION]'
end

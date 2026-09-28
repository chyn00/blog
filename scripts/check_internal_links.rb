# frozen_string_literal: true

require "nokogiri"
require "pathname"
require "uri"
require "yaml"

site_dir = Pathname(ARGV.fetch(0, "_site")).expand_path
config_path = Pathname("_config.yml")
config = config_path.exist? ? YAML.safe_load(config_path.read, permitted_classes: [Time], aliases: true) : {}
baseurl = config.fetch("baseurl", "").to_s.sub(%r{/$}, "")
errors = []

def target_path(site_dir, raw_path, baseurl)
  path = URI.parse(raw_path).path
  return if path.nil? || path.empty?

  path = path.delete_prefix(baseurl) if !baseurl.empty? && (path == baseurl || path.start_with?("#{baseurl}/"))
  path = "/" if path.empty?
  clean = path.sub(%r{^/}, "")
  target = site_dir.join(clean)
  target = target.join("index.html") if path.end_with?("/")
  target
rescue URI::InvalidURIError
  nil
end

site_dir.glob("**/*.html").each do |html_file|
  document = Nokogiri::HTML(html_file.read)

  document.css("a[href], img[src], script[src], link[href]").each do |node|
    attribute = node.key?("href") ? "href" : "src"
    reference = node[attribute]
    next if reference.nil? || reference.empty? || reference.start_with?("#", "mailto:", "tel:", "data:")
    next if reference.match?(%r{\Ahttps?://})

    path_part, fragment = reference.split("#", 2)
    target = if path_part.start_with?("/")
               target_path(site_dir, path_part, baseurl)
             else
               candidate = html_file.dirname.join(path_part).cleanpath
               candidate = candidate.join("index.html") if path_part.end_with?("/")
               candidate
             end

    unless target&.exist?
      errors << "#{html_file.relative_path_from(site_dir)}: missing #{reference}"
      next
    end

    next if fragment.nil? || fragment.empty? || target.extname != ".html"

    target_document = Nokogiri::HTML(target.read)
    errors << "#{html_file.relative_path_from(site_dir)}: missing ##{fragment} in #{reference}" unless target_document.at_css("##{fragment}")
  end
end

if errors.empty?
  puts "Internal links valid"
else
  warn errors.join("\n")
  exit 1
end

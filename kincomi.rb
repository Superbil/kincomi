# encoding: UTF-8
require 'yaml'
require 'date'
require 'fileutils'
require 'open-uri'
require 'nokogiri'
require 'zip'
require 'celluloid/io'
require 'http'

class Comic
  include Celluloid::IO
  F = 50
  attr_reader :name, :author, :download_path

  def initialize(comic_id)
    @id = comic_id
    doc = Nokogiri::HTML(open("http://www.comicvip.com/html/#{@id}.html"))
    @name = doc.css('font[color="#FF6600"]')[0].text
    @author = doc.css('tr').text().scan(/作者.+\s+(.+)/).flatten[0].strip
    @category = doc.css('a.Ch')[0]['onclick'].scan(/,(\d+)\);/).flatten[0].to_i
    @base_url = show_url
    @chapters = []
    doc.css('a.Ch').each do |chapter|
      @chapters << "#{@base_url}?ch=#{chapter['onclick'].scan(/-(\d+).html/).flatten[0]}"
    end
    @download_path = "materials/[#{@author}]#{@name}/"
    FileUtils.mkdir_p @download_path
  end

  def download_all
    @chapters.each_index do |c|
      chapter_doc = Nokogiri::HTML(open(@chapters[c]))
      comic_key = chapter_doc.text.scan(/var cs='(.+)';/).flatten[0]
      chapter = "#{c+1}"
      subkey = create_subkey(comic_key, chapter)
      total_pages = page_count(subkey)
      chapter = chapter.to_s.rjust(4,'0')
      puts "Downloading: [#{@author}]#{@name} Chapter #{chapter.to_i}"
      FileUtils.mkdir_p "#{@download_path}#{chapter}"
      futures = (0...total_pages.to_i).map do |i| 
        [i+1, self.future.download_page(subkey, chapter, i+1)] unless File.exists? "#{@download_path}#{chapter}/#{(i+1).to_s.rjust(3,'0')}.jpg"
      end
      futures.delete nil
      while futures.size != 0
        page, future = futures.shift
        begin
          response = future.value(10)
        rescue
          futures << [page, future]
          next
        end
        File.open("#{@download_path}#{chapter}/#{page.to_s.rjust(3,'0')}.jpg", 'wb') do |f|
          f.write response.to_s
        end
      end
    end
  end

  def download_page(subkey, chapter, page)
    HTTP.get(img_url(subkey, page), socket_class: Celluloid::IO::TCPSocket)
  end

  def chapters
    @chapters.size
  end

  def full_name
    "[#{@author}]#{@name}"
  end

  private
  def show_url
    if [1,2,4,5,6,7,9,12,17,19,21,22].include?(@category)
      "http://new.comicvip.com/show/cool-#{@id}.html"
    else
      "http://new.comicvip.com/show/best-manga-#{@id}.html"
    end
  end

  def str_split_digit(str, start, count)
    str = str[start...(start+count)]
    result = ""
    str.each_char do |c|
      result += c if c=~/[0-9]/
    end
    result
  end

  def str_split(str, start, count)
    str[start...(start+count)]
  end

  def create_subkey(key, ch)
    subkey = ""
    (key.size/F).times do |i|
      if str_split_digit(key, i*F, 4) == ch
        subkey = str_split(key, i*F, F)
        break
      end
    end
    subkey = str_split_digit(key, key.size-F, F) if subkey.empty?
    subkey
  end

  def page_count(subkey)
    str_split_digit(subkey, 7, 3)
  end

  def img_url(subkey, page)
    server = str_split_digit(subkey, 4, 2)
    serial = str_split_digit(subkey, 6, 1)
    serial2 = str_split_digit(subkey, 0, 4)
    padded_page = page.to_s.rjust(3, '0')
    hash = str_split(subkey, img_hash(page) + 10, 3)
    "http://img#{server}.8comic.com/#{serial}/#{@id}/#{serial2}/#{padded_page}_#{hash}.jpg"
  end

  def img_hash(page)
    n = page.to_i
    (((n - 1) / 10) % 10)+(((n-1)%10)*3)
  end
end

def create_zip(directory, out_path)
  Zip::File.open("#{out_path}", Zip::File::CREATE) do |zip_file|
    Dir.new(directory).each do |f|
      unless f[0] == '.'
        zip_file.add f, "#{directory}/#{f}"
      end
    end
  end
end

EBOOK_CONVERT_BIN = "/Applications/calibre.app/Contents/MacOS/ebook-convert"

FileUtils.mkdir_p 'zip_cache'
ARGV.each do |comic_id|
  comic = Comic.new(comic_id)
  comic.download_all
  comic.chapters.times do |chapter|
    chapter_dir = "#{chapter+1}".rjust(4,'0')
    puts "Creating ZIP file for chapter #{chapter+1}"
    create_zip("#{comic.download_path}#{chapter_dir}", "zip_cache/#{chapter_dir}.cbz")
    opt = "--authors \"#{comic.author}\" \
          --series \"#{comic.full_name}\" \
          --series-index #{chapter+1} \
          --output-profile kindle_pw \
          --right2left \
          --title \"#{comic.name} \##{chapter+1}\""
    puts "Creating .mobi for chapter #{chapter+1}"
    `#{EBOOK_CONVERT_BIN} zip_cache/#{chapter_dir}.cbz "generated/#{comic.full_name}-#{chapter_dir}.mobi" #{opt}`
  end
  FileUtils.rm_rf 'zip_cache'
end
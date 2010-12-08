require 'nokogiri'
require 'open-uri'
require 'tzinfo'


class RollsLiveSenate
  
  def self.run(options = {})
    year = Time.now.year
    
    count = 0
    missing_legislators = []
    bad_votes = []
    timed_out = []
    
    # will be referenced by LIS ID as a cache built up as we parse through votes
    legislators = {}
    
    latest_roll = nil
    session = nil
    subsession = nil
    begin
      latest_roll, session, subsession = latest_roll_info
    rescue Timeout::Error
      Report.warning self, "Timeout error on fetching the listing page, can't go on."
      return
    end
    
    unless latest_roll and session and subsession
      Report.failure self, "Couldn't figure out latest roll, or session, or subsession, from the Senate page, aborting.\nlatest_roll: #{latest_roll}, session: #{session}, subsession: #{subsession}"
      return
    end
    
    # check last 20 rolls, see if any are missing from our database
    to_fetch = []
    (latest_roll-19).upto(latest_roll) do |number|
      if Vote.where(:roll_id => "s#{number}-#{year}").first.nil?
        to_fetch << number
      end
    end
    
    if to_fetch.empty?
      Report.success self, "No new rolls for the Senate for #{year}, latest one is #{latest_roll}."
      return
    end
    
    # debug
    # to_fetch = [2]
    # year = 2009
    
    # get each new roll
    to_fetch.each do |number|
      url = url_for number, session, subsession
      
      doc = nil
      begin
        doc = Nokogiri::XML open(url)
      rescue Timeout::Error
        doc = nil
      end
      
      if doc
        roll_id = "s#{number}-#{year}"
        bill_id = bill_id_for doc, session
        voter_ids, voters = votes_for doc, legislators, missing_legislators
        
        roll_type = doc.at("question").text
        question = doc.at("vote_question_text").text
        result = doc.at("vote_result").text
        
        vote = Vote.new :roll_id => roll_id
        vote.attributes = {
          :vote_type => Utils.vote_type_for(roll_type),
          :how => "roll",
          :chamber => "senate",
          :year => year,
          :number => number,
          
          :session => session,
          
          :roll_type => roll_type,
          :question => question,
          :result => result,
          :required => required_for(doc),
          
          :voted_at => voted_at_for(doc),
#           :voter_ids => voter_ids,
#           :voters => voters,
#           :vote_breakdown => Utils.vote_breakdown_for(voters),
        }
        
        if bill_id
          if bill = Utils.bill_for(bill_id)
            vote.attributes = {
              :bill_id => bill_id,
              :bill => bill
            }
          else
            Report.warning self, "Found bill_id #{bill_id} on Senate roll no. #{number}, which isn't in the database."
          end
        end
        
        if vote.save
          count += 1
          puts "[#{roll_id}] Saved successfully"
        else
          bad_votes << {:error_messages => vote.errors.full_messages, :roll_id => roll_id}
          puts "[#{roll_id}] Error saving, will file report"
        end
        
      else
        timed_out << [number]
      end
    end
    
    if bad_votes.any?
      Report.failure self, "Failed to save #{bad_votes.size} roll calls. Attached the last failed roll's attributes and error messages.", {:bad_vote => bad_votes.last}
    end
    
    if missing_legislators.any?
      Report.warning self, "Couldn't look up #{missing_legislators.size} legislators in Senate roll call listing. Vote counts on roll calls may be inaccurate until these are fixed.", {:missing_legislators => missing_legislators}
    end
    
    if timed_out.any?
      Report.warning self, "Timeout error on fetching #{timed_out.size} Senate roll(s), skipping and going onto the next one.", :timed_out => timed_out
    end
    
    Report.success self, "Fetched #{count} new live roll calls from the Senate website."
  end
  
  
  # find the latest roll call number listed on the Senate roll call vote page
  def self.latest_roll_info
    url = "http://www.senate.gov/pagelayout/legislative/a_three_sections_with_teasers/votes.htm"
    doc = Nokogiri::HTML open(url)
    element = doc.css("td.contenttext a").first
    if element and element.text.present?
      number = element.text.to_i
      href = element['href']
      session = href.match(/congress=(\d+)/i)[1].to_i
      subsession = href.match(/session=(\d+)/i)[1].to_i
      
      if number > 0 and session > 0 and subsession > 0
        return number, session, subsession
      else
        nil
      end
    else
      nil
    end
  end
  
  def self.url_for(number, session, subsession)
    "http://www.senate.gov/legislative/LIS/roll_call_votes/vote#{session}#{subsession}/vote_#{session}_#{subsession}_#{zero_prefix number}.xml"
  end
  
  def self.zero_prefix(number)
    if number < 10
      "0000#{number}"
    elsif number < 100
      "000#{number}"
    elsif number < 1000
      "00#{number}"
    elsif number < 10000
      "0#{number}"
    else
      number
    end
  end
  
  def self.required_for(doc)
    doc.at("majority_requirement").text
  end
  
  def self.votes_for(doc, legislators, missing_legislators)
    voter_ids = {}
    voters = {}
    
    # TODO
    
#     doc.search("//vote-data/recorded-vote").each do |elem|
#       vote = (elem / 'vote').text
#       
#       bioguide_id = (elem / 'legislator').first['name-id']

#       if legislators[lis_id]
#         voter = Utils.voter_for legislators[lis_id]
#         bioguide_id = voter[:bioguide_id]
#         voter_ids[bioguide_id] = vote
#         voters[bioguide_id] = {:vote => vote, :voter => voter}
#       else
#         if bioguide_id.to_i == 0
#           missing_legislators << [bioguide_id, filename]
#         else
#           missing_legislators << bioguide_id
#         end
#       end
#     end
    
    [voter_ids, voters]
  end
  
  def self.lookup_and_cache_legislator(element, legislators, missing_legislators)
    # TODO
  end
  
  def self.bill_id_for(doc, session)
    elem = doc.at 'document_name'
    if elem
      code = elem.text.strip.gsub(' ', '').gsub('.', '').downcase
      type = code.gsub /\d/, ''
      number = code.gsub type, ''
      
      type.gsub! "hconres", "hcres" # house uses H CON RES
      
      if !["hr", "hres", "hjres", "hcres", "s", "sres", "sjres", "scres"].include?(type)
        nil
      else
        "#{type}#{number}-#{session}"
      end
    else
      nil
    end
  end
  
  def self.voted_at_for(doc)
    # make sure we're set to EST
    Time.zone = ActiveSupport::TimeZone.find_tzinfo "America/New_York"
    
    Time.parse doc.at("vote_date").text
  end
  
end

require 'net/http'

# Shorten timeout in Net::HTTP
module Net
  class HTTP
    alias old_initialize initialize

    def initialize(*args)
        old_initialize(*args)
        @read_timeout = 8 # 8 seconds
    end
  end
end
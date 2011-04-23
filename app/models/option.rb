class Option < ActiveRecord::Base
  has_many :points
  has_many :positions
  has_many :inclusions
  has_many :point_listings
  
  def format_description
    return self.description.split('\n')
  end
  
  def reference
    return "#{category} #{designator}"
  end
  
end
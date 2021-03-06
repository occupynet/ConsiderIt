class PositionsController < ApplicationController
  protect_from_forgery

  respond_to :html

  POINTS_PER_PAGE = 4
  
  def new
    handle_new_edit(true)
  end

  def edit
    handle_new_edit(false)
  end

  def create
    @option = Option.find(params[:option_id])

    (stance, bucket) = get_stance_val_from_params(params)

    params[:position].update({
      :user_id => !current_user.nil? ? current_user.id : nil,
      :stance => stance,
      :stance_bucket => bucket,
      :published => !current_user.nil? 
    })

    @position = Position.unscoped.find(params[:position][:position_id])
    params[:position].delete(:position_id)
    @position.update_attributes(params[:position])
    @position.save

    if !current_user.nil?
      save_actions(@position)
    else
      # stash until after user registration
      session['position_to_be_published'] = @position.id
    end

    respond_with(@option, @position) do |format|
      format.html { redirect_to(@option) }
      format.js { render :json => { :result => 'successful' }.to_json }
    end
  end
  
  def update
    @option = Option.find(params[:option_id])
    @position = current_user.positions.unscoped.find(params[:id])
    
    (stance, bucket) = get_stance_val_from_params(params)

    params[:position].delete(:position_id)
    @position.update_attributes(params[:position])
    @position.stance = stance
    @position.stance_bucket = bucket
    @position.published = 1
    @position.save

    save_actions(@position)
    
    respond_with(@option, @position) do |format|
      format.html { redirect_to(@option) }
    end
  end
  
  def show
    
  end

  def destroy
    @option = Option.find(params[:option_id])
    if current_user
      @position = Position.unscoped.where(:option_id => @option.id, :user_id => current_user.id).first 
    else
      @position = session.has_key?("position-#{@option.id}") ? Position.unscoped.find(session["position-#{@option.id}"]) : nil
    end
    if @position && @position.published
      redirect_to(option_path(@position.option))
    else
      session.delete('reify_activities')
      session.delete('position_to_be_published')  
      redirect_to root_path
    end
  end
  
protected
  def handle_new_edit(is_new)
    @option = Option.find(params[:option_id])
    @user = current_user

    @title = "#{@option.domain} #{@option.designator} #{@option.name}"
    @keywords = "#{@option.domain} #{@option.category} #{@option.designator} #{@option.name} Washington 2011"
    @description = "Learn more and put your best arguments forward about #{@option.domain} #{@option.category} #{@option.designator} #{@option.short_name}. You'll be voting on it in the 2011 election!"

    if !session.has_key?(@option.id)
      session[@option.id] = {
        :included_points => {},
        :deleted_points => {},
        :written_points => []
      }
    end
    # When we are redirected back to the position page after a user creates their account, 
    # we should save their actions and redirect to results page
    if session.has_key?('reify_activities') && session['reify_activities']
      @position = Position.unscoped.find(session['position_to_be_published'])
      # check to see if this user already had a previous position
      prev_pos = Position.unscoped.where(:option_id => @option.id, :user_id => current_user.id).first
      if prev_pos
        #resolve by combining positions, taking stance from newly submitted...
        prev_pos.stance = @position.stance
        prev_pos.stance_bucket = @position.stance_bucket
        prev_pos.notification_includer = @position.notification_includer
        prev_pos.notification_option_subscriber = @position.notification_option_subscriber
        save_actions(prev_pos)
        prev_pos.save
        @position.point_listings.update_all({:user_id => current_user.id, :position_id => prev_pos.id})
        @position.destroy
      else
        @position.published = true
        @position.user_id = current_user.id
        @position.save
        @position.point_listings.update_all({:user_id => current_user.id})        
        save_actions(@position)
      end

      session.delete('reify_activities')
      session.delete('position_to_be_published')  
      redirect_to(@option)
      return
    end

    if is_new
      if current_user
        @position = Position.unscoped.where(:option_id => @option.id, :user_id => current_user.id).first 
      else
        @position = session.has_key?("position-#{@option.id}") ? Position.unscoped.find(session["position-#{@option.id}"]) : nil
      end
      if @position.nil?
        @position = Position.unscoped.create!( 
          :stance => 0.0, 
          :option_id => @option.id, 
          :user_id => @user ? @user.id : nil
        )
        session["position-#{@option.id}"] = @position.id
      end
    else
      @position = Position.find( params[:id] )
    end

    #TODO: Right now, if you write an unpublished point, then remove it from your list, you will never be able to include it because
    # the following code does not select the unpublished points by the current user or that are stored in session['written_points'].
    # This is an edge case. We should allow users to delete a point before it is published/included by others, which should further
    # relegate this issue to an insignificant edge case. 
    @pro_points = @option.points.pros.not_included_by(current_user, session[@option.id][:included_points].keys).
                    ranked_persuasiveness.paginate(:page => 1, :per_page => POINTS_PER_PAGE)    
    @con_points = @option.points.cons.not_included_by(current_user, session[@option.id][:included_points].keys).
                    ranked_persuasiveness.paginate(:page => 1, :per_page => POINTS_PER_PAGE)

    PointListing.transaction do

      (@pro_points + @con_points).each do |pnt|
        PointListing.create!(
          :option => @option,
          :position => @position,
          :point => pnt,
          :user => @user,
          :context => 1
        )
      end
    end
    
    @included_pros = Point.included_by_stored(current_user, @option).where(:is_pro => true) + 
                     Point.included_by_unstored(session[@option.id][:included_points].keys, @option).where(:is_pro => true)
    @included_cons = Point.included_by_stored(current_user, @option).where(:is_pro => false) + 
                     Point.included_by_unstored(session[@option.id][:included_points].keys, @option).where(:is_pro => false)

    @page = 1
  end

  def save_actions ( position )
    actions = session[position.option_id]
    pp 'CHECKING INCLUSIONS'

    actions[:included_points].each do |point_id, value|

      if Inclusion.where( :position_id => position.id ).where( :point_id => point_id).where( :user_id => position.user_id ).count == 0
        Inclusion.create!( { 
          :point_id => point_id,
          :user_id => position.user_id,
          :position_id => position.id,
          :option_id => position.option_id
        } )      
      end
    end
    actions[:included_points] = {}

    actions[:written_points].each do |pnt_id|
      pnt = Point.unscoped.find( pnt_id )

      if pnt.user_id.nil?
        pnt.user_id = position.user_id
        pnt.published = 1
        pnt.notify_parties
      end
      pnt.position_id = position.id
      pnt.update_attributes({"score_stance_group_#{position.stance_bucket}".intern => 0.001})
      #Inclusion.create!( { 
      #  :point_id => pnt_id,
      #  :user_id => position.user_id,
      #  :position_id => position.id,
      #  :option_id => position.option_id
      #} )      
      pnt.update_absolute_score
    end
    actions[:written_points] = []

    actions[:deleted_points].each do |point_id, value|
      pp point_id
      pp value
      current_user.inclusions.where(:point_id => point_id).each do |inc|
        inc.destroy
      end
    end
    actions[:deleted_points] = {}
  end

  def get_stance_val_from_params( params )

    stance = -1 * Float(params[:position][:stance])
    if stance > 1
      stance = 1
    elsif stance < -1
      stance = -1
    end
    bucket = get_bucket(stance)
    
    return stance, bucket
  end
      
      
  def get_bucket(value)
    if value == -1
      return 0
    elsif value == 1
      return 6
    elsif value <= 0.05 && value >= -0.05
      return 3
    elsif value >= 0.5
      return 5
    elsif value <= -0.5
      return 1
    elsif value >= 0.05
      return 4
    elsif value <= -0.05
      return 2
    end   
  end        
end

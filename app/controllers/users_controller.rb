class UsersController < ApplicationController
  def index
    @users = User.all
  end

  def update
    @user = User.find(params[:id])
    if @user.update(user_params)
      redirect_to(@user)
    else
      render "edit"
    end
  end

  def create
    if (@user = User.new(user_params)).save
      redirect_to users_path
    else
      render :new
    end
  end

  def new
    @user = User.new
  end

  def show
    @user = User.find(params[:id])
    render json: @user
  end

  def edit
    @user = User.find(params[:id])
  end

  def destroy
    User.find(params[:id]).destroy
    redirect_to users_path
  end

  def user_params
    params.require(:user).permit(:email, :name)
  end
end

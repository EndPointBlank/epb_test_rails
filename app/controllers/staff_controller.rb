# frozen_string_literal: true

class StaffController < AuthenticatedController
  version ["1"], only: [:index, :create, :destroy], state: "Current"

  def index
    render json: { staff: Staff.all }
  end

  def create
    staff = Staff.new(staff_params)

    if staff.save
      render json: { staff: staff }, status: :created
    else
      render json: { errors: staff.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    staff = Staff.find(params[:id])
    staff.destroy
    render json: { message: "Staff member removed" }
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Staff member not found" }, status: :not_found
  end

  private

  def staff_params
    params.require(:staff).permit(:first_name, :last_name, :staff_type, :location)
  end
end

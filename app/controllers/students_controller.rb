# frozen_string_literal: true

class StudentsController < AuthenticatedController
  version ["1"], only: [:index, :create, :destroy], state: "Current"

  def index
    EndPointBlank::Writers::LogWriter.info("Fetching students list")
    render json: { students: Student.all }
  end

  def create
    student = Student.new(student_params)
    if student.save
      render json: { student: student }, status: :created
    else
      render json: { errors: student.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    student = Student.find(params[:id])
    student.destroy
    render json: { message: "Student removed" }
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Student not found" }, status: :not_found
  end

  private

  def student_params
    params.require(:student).permit(:first_name, :last_name, :birth_date, :location)
  end
end

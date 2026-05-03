class CreateStaff < ActiveRecord::Migration[8.0]
  def change
    create_table :staffs do |t|
      t.string :first_name
      t.string :last_name
      t.string :staff_type
      t.string :location

      t.timestamps
    end
  end
end

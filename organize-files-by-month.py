#!/usr/bin/env python3
import os
import shutil
from datetime import datetime

# Function to create a directory if it doesn't exist
def create_directory_if_not_exists(directory):
    if not os.path.exists(directory):
        os.makedirs(directory)

# Main function to organize files
def organize_files_by_date():
    for filename in os.listdir('.'):
        if os.path.isfile(filename):
            # Getting the last modification time and formatting it
            mod_time = os.path.getmtime(filename)
            year_month = datetime.fromtimestamp(mod_time).strftime('%Y.%m')

            # Creating a directory for the year and month if it doesn't exist
            create_directory_if_not_exists(year_month)

            # Moving the file to the respective directory
            shutil.move(filename, os.path.join(year_month, filename))
            print(f'Moved {filename} to {year_month}/')

# Run the function
organize_files_by_date()

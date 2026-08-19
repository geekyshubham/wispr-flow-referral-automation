#!/usr/bin/env osascript
tell application "TextEdit"
  activate
  if (count of documents) = 0 then make new document
  delay 0.3
end tell
tell application "System Events"
  tell process "TextEdit"
    set frontmost to true
    try
      click text area 1 of scroll area 1 of group 1 of window 1
    end try
  end tell
end tell
delay 0.3

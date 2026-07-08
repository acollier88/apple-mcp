-- IDEAS #12: push-based email capture. Attach this to a Mail rule
-- (Mail > Settings > Rules > "Run AppleScript") and matching incoming
-- messages become [mail]-tagged reminders in the inbox, with sender,
-- subject, and message id in the notes for provenance. Triage then routes
-- them like any other capture ([mail]-only items count as untagged).
--
-- Install (compiles + copies to Mail's sandboxed scripts dir):
--   make mail-rule
-- Mail must be running for rules to fire; that's the one caveat vs the
-- polling mail_scan. All values pass through `quoted form of` — never
-- interpolated raw into the shell.
--
-- Raw event/class codes are used instead of Mail terminology («event
-- emalcpma» = "perform mail action with messages", sndr/subj/meid =
-- sender/subject/message id) because `using terms from application "Mail"`
-- fails to compile on macOS 27 beta 3 even though the sdef still declares
-- the terms. The codes are stable; revisit when the beta heals.

property appleTasksBin : "/Users/andrewcollier/Code/apple-mcp/.build/release/apple-tasks"
property inboxList : "Reminders"

on captureMessage(theSender, theSubject, theMessageId)
	set theTitle to theSubject
	if theTitle is "" then set theTitle to "(no subject)"
	set theNotes to "From: " & theSender & linefeed & "Subject: " & theSubject
	if theMessageId is not "" then set theNotes to theNotes & linefeed & "Message-ID: " & theMessageId
	do shell script "APPLE_TASKS_CALLER=mail-rule " & quoted form of appleTasksBin & ¬
		" add --list " & quoted form of inboxList & ¬
		" --tag mail --notes " & quoted form of theNotes & ¬
		" " & quoted form of theTitle
end captureMessage

on «event emalcpma» theMessages given «class pmar»:theRule
	repeat with theMessage in theMessages
		set theSender to ""
		set theSubject to ""
		set theMessageId to ""
		tell application "Mail"
			try
				set theSender to («class sndr» of theMessage) as string
			end try
			try
				set theSubject to («class subj» of theMessage) as string
			end try
			try
				set theMessageId to («class meid» of theMessage) as string
			end try
		end tell
		my captureMessage(theSender, theSubject, theMessageId)
	end repeat
end «event emalcpma»

-- Manual smoke test: `osascript apple-tasks-capture.scpt` captures a fake
-- message so the plumbing can be verified without waiting for real mail.
on run
	captureMessage("smoke-test@example.com", "Mail rule capture smoke test", "<smoke-test@apple-tasks>")
end run

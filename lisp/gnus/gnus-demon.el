;;; gnus-demon.el --- daemonic Gnus behavior  -*- lexical-binding: t; -*-

;; Copyright (C) 1995-2025 Free Software Foundation, Inc.

;; Author: Lars Magne Ingebrigtsen <larsi@gnus.org>
;; Keywords: news

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;;; Code:

(eval-when-compile (require 'cl-lib))

(require 'gnus)
(require 'gnus-int)
(require 'nnheader)
(require 'nntp)
(require 'nnmail)

(defgroup gnus-demon nil
  "Demonic behavior."
  :group 'gnus)

(defcustom gnus-demon-handlers nil
  "Alist of daemonic handlers to be run at intervals.
Each handler is a list on the form

\(FUNCTION TIME IDLE)

FUNCTION is the function to be called.  TIME is the number of
`gnus-demon-timestep's between each call.
If nil, never call.  If t, call each `gnus-demon-timestep'.

If IDLE is t, only call each time Emacs has been idle for TIME.
If IDLE is a number, only call when Emacs has been idle more than
this number of `gnus-demon-timestep's.
If IDLE is nil, don't care about idleness.
If IDLE is a number and TIME is nil, then call once each time
Emacs has been idle for IDLE `gnus-demon-timestep's."
  :type '(repeat (list function
		       (choice :tag "Time"
			       (const :tag "never" nil)
			       (const :tag "one" t)
			       (integer :tag "steps" 1))
		       (choice :tag "Idle"
			       (const :tag "don't care" nil)
			       (const :tag "for a while" t)
			       (integer :tag "steps" 1)))))

(defcustom gnus-demon-timestep 60
  "Number of seconds in each demon timestep."
  :type 'integer)

;;; Internal variables.

(defvar gnus-demon-timers nil
  "Plist of idle timers which are running.")
(defvar gnus-inhibit-demon nil
  "If non-nil, no daemonic function will be run.")

;;; Functions.

(defun gnus-demon-add-handler (function time idle)
  "Add the handler FUNCTION to be run at TIME and IDLE."
  ;; First remove any old handlers that use this function.
  (gnus-demon-remove-handler function)
  ;; Then add the new one.
  (push (list function time idle) gnus-demon-handlers)
  (gnus-demon-init))

(defun gnus-demon-remove-handler (function &optional no-init)
  "Remove the handler FUNCTION from the list of handlers."
  (gnus-alist-pull function gnus-demon-handlers)
  (unless no-init
    (gnus-demon-init)))

(defun gnus-demon-idle-since ()
  "Return the number of seconds since when Emacs is idle."
  (float-time (or (current-idle-time) 0)))

(defun gnus-demon-run-callback (func &optional idle time special)
  "Run FUNC if Emacs has been idle for longer than IDLE seconds.
If not, and a TIME is given, restart a new idle timer, so FUNC
can be called at the next opportunity.  Such a special idle run
is marked with SPECIAL."
  (unless gnus-inhibit-demon
    (cl-block run-callback
      (when (eq idle t)
        (setq idle 0.001))
      (cond (special
             (setq gnus-demon-timers
                   (plist-put gnus-demon-timers func
                              (run-with-timer time time 'gnus-demon-run-callback
                                              func idle time))))
            ((and idle (> idle (gnus-demon-idle-since)))
             (when time
               (cancel-timer (plist-get gnus-demon-timers func))
               (setq gnus-demon-timers
                     (plist-put gnus-demon-timers func
				(run-with-idle-timer idle nil
						     'gnus-demon-run-callback
						     func idle time t))))
             (cl-return-from run-callback)))
      (with-local-quit
        (ignore-errors
          (funcall func))))))

(defun gnus-demon-init ()
  "Initialize the Gnus daemon."
  (interactive)
  (gnus-demon-cancel)
  (dolist (handler gnus-demon-handlers)
    ;; Set up the timer.
    (let* ((func (nth 0 handler))
           (time (nth 1 handler))
           (idle (nth 2 handler))
           ;; Compute time according with timestep.
           ;; If t, replace by 1
           (time (cond ((eq time t)
                        gnus-demon-timestep)
                       ((null time)
			nil)
		       ((stringp time)
			(* (gnus-demon-time-to-step time) gnus-demon-timestep))
                       (t
			(* time gnus-demon-timestep))))
	   (idle (cond ((numberp idle)
			(* idle gnus-demon-timestep))
		       ((and (eq idle t) (numberp time))
			time)
		       (t
			idle)))

           (timer
            (cond
             ;; (func nil number)
             ;; Only call when Emacs has been idle for `idle'
             ((and (null time) (numberp idle))
              (run-with-idle-timer idle t 'gnus-demon-run-callback func))
             ;; (func number any)
             ;; Call every `time'
             ((integerp time)
              (run-with-timer time time 'gnus-demon-run-callback
			      func idle time))
             ;; (func string any)
             ((stringp time)
              (run-with-timer time (* 24 60 60) 'gnus-demon-run-callback
			      func idle)))))
      (when timer
        (setq gnus-demon-timers (plist-put gnus-demon-timers func timer))))))

(defun gnus-demon-time-to-step (time)
  "Find out how many steps to TIME, which is on the form \"17:43\"."
  (let* ((now (current-time))
	 ;; obtain NOW as discrete components -- make a vector for speed
	 (nowParts (decode-time now))
	 ;; obtain THEN as discrete components
	 (thenParts (parse-time-string time))
	 (thenHour (decoded-time-hour thenParts))
	 (thenMin (decoded-time-minute thenParts))
	 ;; convert time as elements into number of seconds since EPOCH.
	 (then (encode-time
		0
		thenMin
		thenHour
		;; If THEN is earlier than NOW, make it
		;; same time tomorrow.  Doc for encode-time
		;; says that this is OK.
		(+ (decoded-time-day nowParts)
		   (if (or (< thenHour (decoded-time-hour nowParts))
			   (and (= thenHour
				   (decoded-time-hour nowParts))
				(<= thenMin
				    (decoded-time-minute nowParts))))
		       1 0))
		(decoded-time-month nowParts)
		(decoded-time-year nowParts)
		(decoded-time-weekday nowParts)
		(decoded-time-dst nowParts)
		(decoded-time-zone nowParts)))
	 (diff (float-time (time-subtract then now))))
    ;; Return number of timesteps in the number of seconds.
    (round diff gnus-demon-timestep)))

(gnus-add-shutdown 'gnus-demon-cancel 'gnus)

(defun gnus-demon-cancel ()
  "Cancel any Gnus daemons."
  (interactive)
  (dotimes (i (/ (length gnus-demon-timers) 2))
    (cancel-timer (nth (1+ (* i 2)) gnus-demon-timers)))
  (setq gnus-demon-timers nil))

(defun gnus-demon-add-disconnection ()
  "Add daemonic server disconnection to Gnus."
  (gnus-demon-add-handler 'gnus-demon-close-connections nil 30))

(defun gnus-demon-close-connections ()
  (save-window-excursion
    (gnus-close-backends)))

(defun gnus-demon-add-nntp-close-connection ()
  "Add daemonic nntp server disconnection to Gnus.
If no commands have gone out via nntp during the last five
minutes, the connection is closed."
  (gnus-demon-add-handler 'gnus-demon-nntp-close-connection 5 nil))

(defun gnus-demon-nntp-close-connection ()
  (save-window-excursion
    (when (time-less-p 300 (time-since nntp-last-command-time))
      (nntp-close-server))))

(defun gnus-demon-add-scanmail ()
  "Add daemonic scanning of mail from the mail backends."
  (gnus-demon-add-handler 'gnus-demon-scan-mail 120 60))

(defun gnus-demon-scan-mail ()
  (save-window-excursion
    (let ((servers gnus-opened-servers)
	  server
	  (nnmail-fetched-sources (list t)))
      (while (setq server (car (pop servers)))
	(and (gnus-check-backend-function 'request-scan (car server))
	     (or (gnus-server-opened server)
		 (gnus-open-server server))
	     (gnus-request-scan nil server))))))

(defun gnus-demon-add-rescan ()
  "Add daemonic scanning of new articles from all backends."
  (gnus-demon-add-handler 'gnus-demon-scan-news 120 60))

(defun gnus-demon-scan-news ()
  (let ((win (current-window-configuration)))
    (unwind-protect
	(save-window-excursion
	  (when (gnus-alive-p)
	    (with-current-buffer gnus-group-buffer
	      (gnus-group-get-new-news))))
      (set-window-configuration win))))

(defun gnus-demon-add-scan-timestamps ()
  "Add daemonic updating of timestamps in empty newgroups."
  (gnus-demon-add-handler 'gnus-demon-scan-timestamps nil 30))

(defun gnus-demon-scan-timestamps ()
  "Set the timestamp on all newsgroups with no unread and no ticked articles."
  (when (gnus-alive-p)
    (let ((cur-time (current-time))
	  (newsrc (cdr gnus-newsrc-alist))
	  info group unread has-ticked)
      (while (setq info (pop newsrc))
	(setq group (gnus-info-group info)
	      unread (gnus-group-unread group)
	      has-ticked (cdr (assq 'tick (gnus-info-marks info))))
	(when (and (numberp unread)
		   (= unread 0)
		   (not has-ticked))
	  (gnus-group-set-parameter group 'timestamp cur-time))))))

(provide 'gnus-demon)

;;; gnus-demon.el ends here

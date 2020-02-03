;;; versuri --- The lyrics package -*- lexical-binding: t -*-

;; Copyright (C) 2020 Mihai Olteanu

;; Author: Mihai Olteanu <mihai_olteanu@fastmail.fm>
;; Version: 1.0
;; Package-Requires: ((emacs "26.1") (request "0.3.0") (anaphora "1.0.4") (elquery "0.1.0") (s "1.12.0") (ivy "0.11.0"))
;; Keywords: music
;; URL: https://github.com/mihaiolteanu/versuri/

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; A package to fetch lyrics from well-known websites and store them in a local
;; sqlite database.

;; Features:
;; - makeitpersonal, genius, songlyrics, metrolyrics, musixmatch and azlyrics
;; are all supported
;; - add new websites or modify existing ones with `versuri-add-website'
;; - search the database with ivy-read and either for all the entries in the
;; database, all the entries for a given artist or all the entries where the
;; lyrics field contains a given string.
;; - synchronous bulk request for lyrics for a given list of songs.

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 'request)
(require 'elquery)
(require 's)
(require 'esqlite)
(require 'ivy)

(defconst versuri--db-stream
  (let ((db (concat (xdg-config-home) "/versuri.db")))
    (esqlite-execute db
     (concat "CREATE TABLE IF NOT EXISTS lyrics ("
             "id     INTEGER PRIMARY KEY AUTOINCREMENT "
             "               UNIQUE "
             "               NOT NULL, "
             "artist TEXT    NOT NULL "
             "               COLLATE NOCASE, "
             "song   TEXT    NOT NULL "
             "               COLLATE NOCASE, "
             "lyrics TEXT    COLLATE NOCASE);"))
    (esqlite-stream-open db))
  "The storage place of all succesfully retrieved lyrics.
An empty table and a new db file is created on the first usage.")

(defun versuri--db-read (query)
  "Call the QUERY on the database and return the result."
  (esqlite-stream-read versuri--db-stream query))

(defun versuri--db-get-lyrics (artist song)
  "Retrieve the stored lyrics for ARTIST and SONG."
  (aif (versuri--db-read
        (format "SELECT lyrics FROM lyrics WHERE artist=\"%s\" AND song=\"%s\""
                artist song))
      (car (car it))))

(defun versuri--db-search-lyrics-like (str)
  "Retrieve all entries that contain lyrics like STR."
  (versuri--db-read
   (format "SELECT * from lyrics WHERE lyrics like '%%%s%%'" str)))

(defun versuri--db-artists-like (artist)
  "Retrieve all entries that contain artists like ARTIST."
  (versuri--db-read
   (format "SELECT * from lyrics WHERE artist like '%%%s%%'" artist)))

(defun versuri--db-all-entries ()
  "Select everything from the database."
  (versuri--db-read "SELECT * from lyrics"))

(defun versuri--db-save-lyrics (artist song lyrics)
  "Save the LYRICS for ARTIST and SONG in the database."
  (esqlite-stream-execute versuri--db-stream
   (format "INSERT INTO lyrics(artist,song,lyrics) VALUES(\"%s\", \"%s\", \"%s\")"
           artist song (s-trim lyrics))))

(defun versuri-ivy-search (str)
  "Search the database for all entries that match STR.
Use ivy to let the user select one of the entries and return it.
Each entry contains the artist name, song name and a verse line.

If STR is empty, this is a search through all the entries in the
database.

If STR starts with an empty space, this is a search for all
artists that contain STR in their name.

Otherwise, this is a search for all the lyrics that contain STR.
There can be more entries with the same artist and song name if
the STR matches multiple lines in the lyrics."
  (interactive "MSearch lyrics: ")
  (let (res)
    (ivy-read
     "Select Lyrics: "
     (let ((entries (cond ((s-blank? (s-trim str))
                           (versuri--db-all-entries))
                          ((s-equals-p " " (substring str 0 1))
                           (versuri--db-artists-like (s-trim str)))
                          (t (versuri--db-search-lyrics-like str)))))
       (cl-multiple-value-bind (artist-max-len song-max-len)
           (cl-loop for entry in entries
                    maximize (length (cadr entry)) into artist
                    maximize (length (caddr entry)) into song
                    finally (return (cl-values artist song)))
         (mapcan
          (lambda (song)
            (mapcar (lambda (verse)
                 (list
                  ;; Build a table of artist/song/verse with padding.
                  (format (s-format  "%-$0s   %-$1s   %s" 'elt
                                     ;; Add the padding
                                     `(,artist-max-len ,song-max-len))
                          ;; Add the actual artist, song and verse.
                          (cadr song) (caddr song) verse)
                  ;; Artist and song, recoverable in :action lambda.
                  (cadr song) (caddr song)))
               ;; Go through all the verses in the lyrics column for each entry.
               (if (not (or (seq-empty-p str)
                            (s-equals-p " " (substring str 0 1))))
                   (seq-uniq
                    (mapcan (lambda (line)
                              (s-match (format ".*%s.*" str) line))
                            (s-lines (cadddr song))))
                 ;; First line of the lyrics.
                 (list (car (s-lines (cadddr song)))))))
          ;; All entries in db that contain str in the lyrics column.
          entries)))
     :action (lambda (song)
               (setf res (list (cadr song) (caddr song)))))
    res))

(defun versuri--elquery-read-string (string)
  "Return the AST of the html string STRING as a plist.
Like the original elquery-read-string, but don't remove spaces.

The original elquery-read-string removes all newlines (issue on
github created), which means all the parsed lyrics are returned
in one giant string with no way of knowing where one line ends
and the other one begins.  The solution in this defun uses an
internal elquery function, which might be a problem in the
future.

Also, the original function does not parse utf8 chars (issue on
github also created). (set-buffer-multibyte nil) solves it."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert string)
    (let ((tree (libxml-parse-html-region (point-min) (point-max))))
      (thread-last tree
        (elquery--parse-libxml-tree nil)))))

(defconst versuri--websites nil
  "A list of all the websites where lyrics can be searched.")

(cl-defstruct versuri--website
  name template separator query)

(defun versuri-add-website (name template separator query)
  "Define a new website where lyrics can be searched.
If a website with the given NAME already exists, replace it.  If
not, use the NAME, TEMPLATE SEPARATOR and QUERY to define a new
lyrics website structure and add it to the list of known websites
for lyrics searches.

NAME is a user-friendly name of the website.

TEMPLATE is the website url with placeholders for ${artist} and
${song}.  Replacing these templates with actual artist and song
names results in a valid url that can be used to return the
lyrics.

SEPARATOR is used in conjunction with TEMPLATE to build the
requested url.  The empty spaces in the artist and song name are
replaced with SEPARATORs.  Some websites use dashes, others plus
signs, for example.

QUERY is used in the parsing phase of the html response.  It
specifies the css selectors used by elquery to extract the lyrics
part of the html page.

See the already defined websites for examples for all of the
above parameters."
  (let ((new-website (make-versuri--website
                      :name name
                      :template template
                      :separator separator
                      :query query)))
    ;; Replace the entry if there is already a website with the same name.
    (aif (cl-position name versuri--websites
                      :test #'equal
                      :key #'versuri--website-name)
        (setf (nth it versuri--websites) new-website)
      ;; Freshly add it, otherwise.
      (push new-website versuri--websites))))

(versuri-add-website "makeitpersonal"
  "https://makeitpersonal.co/lyrics?artist=${artist}&title=${song}"
  "-" "p")

(versuri-add-website "genius"
  "https://genius.com/${artist}-${song}-lyrics"
  "-" "div.lyrics p")

(versuri-add-website "songlyrics"
  "http://www.songlyrics.com/${artist}/${song}-lyrics/"
  "-" "p#songLyricsDiv")

(versuri-add-website "metrolyrics"
  "http://www.metrolyrics.com/${song}-lyrics-${artist}.html"
  "-" "p.verse")

(versuri-add-website "musixmatch"
  "https://www.musixmatch.com/lyrics/${artist}/${song}"
  "-" "p.mxm-lyrics__content span")

(versuri-add-website "azlyrics"
  "https://www.azlyrics.com/lyrics/${artist}/${song}.html"
  "" "div.container.main-page div.row div:nth-child(2) div:nth-of-type(5)")

(defun versuri--build-url (website artist song)
  "Use the WEBSITE definition to build a valid url.
ARTIST and SONG are replaced in the WEBSITE template."
  (let ((sep (versuri--website-separator website)))
    (s-format (versuri--website-template website)
              'aget
              `(("artist" . ,(s-replace " " sep artist))
                ("song"   . ,(s-replace " " sep song))))))

(defun versuri--request (website artist song callback)
  "Request the lyrics for ARTIST and SONG at WEBSITE.
`callback' is called with the response data or with nil in case
of an error."
  (request (versuri--build-url website artist song)
           :parser 'buffer-string
           :sync nil
           :success (cl-function
                     (lambda (&key data &allow-other-keys)
                       (funcall callback data)))
           :error (lambda ()
                    (funcall callback nil)))
  nil)

(defun versuri--parse (website html)
  "Use the WEBSITE definition to parse the HTML response."
  (let* ((css (versuri--website-query website))
         (parsed (elquery-$ css (versuri--elquery-read-string html)))
         (lyrics))
    ;; Some lyrics are split into multiple elements (musixmatch), otherwise, an
    ;; (elquery-text (car el)) would have been enough, which is basically what
    ;; happens if there is only one element, anyway.
    (mapc (lambda (el)
            (let ((text (elquery-text el)))
              (setf lyrics (concat
                            (if (equal (versuri--website-name website)
                                       "songlyrics")
                                ;; Songlyrics adds <br> elements after each
                                ;; line.
                                (s-replace "" "" text)
                              text)
                            "\n\n"
                            lyrics))))
       parsed)
    lyrics))

(cl-defun versuri-lyrics
    (artist song callback &optional (websites versuri--websites))
  "Pass the lyrics for ARTIST and SONG to the CALLBACK function.

Async call. If the lyrics is found in the database, use that.
Otherwise, search through WEBSITES for them. If found, save
them to the database and recursivelly call this function again.

By default, WEBSITES is bound to the list of all the known
websites. To avoid getting banned, a random website is taken on
every request. If the lyrics is not found on that website, repeat
the call with the remaining websites."
  (if-let (lyrics (versuri--db-get-lyrics artist song))
      (funcall callback lyrics)
    (when-let (website (nth (random (length websites))
                            websites))
        (versuri--request website artist song
          (lambda (resp)
            (if (and resp
                     ;; makeitpersonal
                     (not (s-contains? "Sorry, We don't have lyrics" resp)))
                ;; Positive response
                (when-let (lyrics (versuri--parse website resp))
                  (versuri--db-save-lyrics artist song lyrics)
                  (versuri-lyrics artist song callback))
              ;; Lyrics not found, try another website.
              (versuri-lyrics artist song callback
                              (-remove-item website websites))))))))

(defun versuri-display (artist song)
  "Search and display the lyrics for ARTIST and SONG in a buffer.

Async call.  When found, the lyrics are inserted in a new text,
read-only buffer.  If the buffer with the same lyrics exists,
switch to it.  Inside the buffer, `q' is bound to
`kill-current-buffer'"
  (versuri-lyrics artist song
    (lambda (lyrics)
      (let ((name (format "%s - %s | lyrics" artist song)))
        (aif (get-buffer name)
            (switch-to-buffer it)
          (let ((b (generate-new-buffer name)))
            (with-current-buffer b
              (insert (format "%s - %s\n\n" artist song))
              (insert lyrics)
              (read-only-mode)
              (local-set-key (kbd "q") 'kill-current-buffer))
            (switch-to-buffer b)))))))

(defun versuri-save (artist song)
  "Search and save the lyrics for ARTIST and SONG.

Async call.  When found, the lyrics are saved in the database.
If lyrics already in the database, do nothing."
  (versuri-lyrics artist song #'ignore))

(defun versuri-save-bulk (songs max-timeout)
  "Save the lyrics for all SONGS.

SONGS is a list of '(artist song) lists.
To avoid getting banned by the lyrics websites, wait a maximum of
MAX-TIMEOUT seconds between requests.

Sync call! Depending on the number of entries in the SONGS list,
it can take a while.  In the meantime, Emacs will be blocked.
Better use it while on a coffee break."
  (dolist (song songs)
    (save-lyrics (car song) (cadr song))
    (sleep-for (random max-timeout))))

(provide 'versuri)

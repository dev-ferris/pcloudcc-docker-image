package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"
)

// StatusHandler renders the main status page.
func StatusHandler(sw *StatusWatcher) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}

		s := sw.Get()
		data := map[string]any{
			"Status":    s,
			"StateCSS":  stateCSS(s.State),
			"StateText": stateText(s.State, s.Mounted),
			"Active":    "status",
		}

		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		if err := templates.ExecuteTemplate(w, "status.html", data); err != nil {
			log.Printf("Template error: %v", err)
		}
	})
}

// StatusAPIHandler returns the current status as JSON (for JS polling).
func StatusAPIHandler(sw *StatusWatcher) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s := sw.Get()
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(s)
	})
}

// LogsPageHandler renders the logs viewer page.
func LogsPageHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		data := map[string]any{"Active": "logs"}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		if err := templates.ExecuteTemplate(w, "logs.html", data); err != nil {
			log.Printf("Template error: %v", err)
		}
	})
}

// LogsStreamHandler provides an SSE endpoint that streams log lines.
func LogsStreamHandler(lt *LogTailer) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		flusher, ok := w.(http.Flusher)
		if !ok {
			http.Error(w, "Streaming not supported", http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("Connection", "keep-alive")
		w.Header().Set("X-Accel-Buffering", "no") // Nginx proxy support

		ch := lt.Subscribe()
		defer lt.Unsubscribe(ch)

		// Send initial keepalive.
		fmt.Fprintf(w, ": connected\n\n")
		flusher.Flush()

		for {
			select {
			case line := <-ch:
				fmt.Fprintf(w, "data: %s\n\n", escapeSSE(line))
				flusher.Flush()
			case <-r.Context().Done():
				return
			}
		}
	})
}

// SetupPageHandler renders the first-time login form.
func SetupPageHandler(sw *StatusWatcher) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s := sw.Get()
		if s.SetupDone {
			http.Redirect(w, r, "/", http.StatusSeeOther)
			return
		}

		data := map[string]any{
			"Active": "setup",
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		if err := templates.ExecuteTemplate(w, "setup.html", data); err != nil {
			log.Printf("Template error: %v", err)
		}
	})
}

// SetupSubmitHandler processes the login form submission.
func SetupSubmitHandler(sm *SetupManager, sw *StatusWatcher) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s := sw.Get()
		if s.SetupDone {
			http.Redirect(w, r, "/", http.StatusSeeOther)
			return
		}

		if err := r.ParseForm(); err != nil {
			renderSetupResult(w, "Invalid form data.", false)
			return
		}

		email := strings.TrimSpace(r.FormValue("email"))
		password := r.FormValue("password")
		twofa := strings.TrimSpace(r.FormValue("twofa"))

		if email == "" || password == "" {
			renderSetupResult(w, "Email and password are required.", false)
			return
		}

		if err := sm.RequestLogin(email, password, twofa); err != nil {
			log.Printf("Setup request error: %v", err)
			renderSetupResult(w, "Failed to submit login request.", false)
			return
		}

		// Poll for result (up to 90 seconds — pcloudcc can be slow on first login).
		result, ok := sm.PollResult(90 * time.Second)
		renderSetupResult(w, result, ok)
	})
}

func renderSetupResult(w http.ResponseWriter, message string, success bool) {
	data := map[string]any{
		"Active":  "setup",
		"Message": message,
		"Success": success,
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := templates.ExecuteTemplate(w, "setup.html", data); err != nil {
		log.Printf("Template error: %v", err)
	}
}

// escapeSSE ensures no newlines break the SSE protocol.
func escapeSSE(s string) string {
	return strings.ReplaceAll(strings.ReplaceAll(s, "\r\n", " "), "\n", " ")
}

func stateCSS(state string) string {
	switch state {
	case "running":
		return "green"
	case "setup_required":
		return "yellow"
	case "stopped":
		return "red"
	default:
		return "gray"
	}
}

func stateText(state string, mounted bool) string {
	switch state {
	case "running":
		if mounted {
			return "Online — Drive Mounted"
		}
		return "Online — Mounting..."
	case "setup_required":
		return "Setup Required"
	case "stopped":
		return "Stopped"
	default:
		return "Unknown"
	}
}

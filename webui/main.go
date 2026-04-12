// pcloudcc-webui — lightweight management sidecar for pcloudcc Docker containers.
// Zero external dependencies — Go standard library only.
package main

import (
	"crypto/tls"
	"embed"
	"flag"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"os"
	"time"
)

//go:embed templates/*.html static/*
var content embed.FS

var templates *template.Template

// Config holds the runtime configuration parsed from environment variables.
type Config struct {
	Port      string
	User      string
	Pass      string
	TLS       bool
	ConfigDir string // pcloud config dir (read-only, contains data.db)
	SharedDir string // shared volume (read-write, status/logs/login protocol)
}

func configFromEnv() Config {
	c := Config{
		Port:      envOr("WEBUI_PORT", "8080"),
		User:      envOr("WEBUI_USER", "admin"),
		Pass:      os.Getenv("WEBUI_PASS"),
		TLS:       envOr("WEBUI_TLS", "false") == "true",
		ConfigDir: envOr("PCLOUD_CONFIG_DIR", "/pcloud-config"),
		SharedDir: envOr("PCLOUD_SHARED_DIR", "/pcloud-shared"),
	}
	if c.Pass == "" {
		log.Fatal("WEBUI_PASS environment variable is required")
	}
	return c
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func main() {
	flag.Parse()

	cfg := configFromEnv()

	var err error
	templates, err = template.ParseFS(content, "templates/*.html")
	if err != nil {
		log.Fatalf("Failed to parse templates: %v", err)
	}

	// Start background watchers.
	statusWatcher := NewStatusWatcher(cfg.SharedDir, cfg.ConfigDir)
	go statusWatcher.Run()

	logTailer := NewLogTailer(cfg.SharedDir + "/pcloudcc.log")
	go logTailer.Run()

	setupMgr := NewSetupManager(cfg.SharedDir, cfg.ConfigDir)
	cryptoMgr := NewCryptoManager(cfg.SharedDir)

	// Set up routes.
	mux := http.NewServeMux()

	auth := BasicAuth(cfg.User, cfg.Pass)

	mux.Handle("GET /", auth(StatusHandler(statusWatcher)))
	mux.Handle("POST /crypto", auth(CryptoUnlockHandler(cryptoMgr, statusWatcher)))
	mux.Handle("GET /logs", auth(LogsPageHandler()))
	mux.Handle("GET /api/logs/stream", auth(LogsStreamHandler(logTailer)))
	mux.Handle("GET /setup", auth(SetupPageHandler(statusWatcher)))
	mux.Handle("POST /setup", auth(SetupSubmitHandler(setupMgr, statusWatcher)))
	mux.Handle("GET /api/status", auth(StatusAPIHandler(statusWatcher)))

	// Serve embedded static files.
	mux.Handle("GET /static/", http.FileServerFS(content))

	addr := ":" + cfg.Port
	srv := &http.Server{
		Addr:         addr,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 0, // SSE requires no write timeout
		IdleTimeout:  120 * time.Second,
	}

	if cfg.TLS {
		cert, key, err := generateSelfSignedCert()
		if err != nil {
			log.Fatalf("Failed to generate TLS cert: %v", err)
		}
		srv.TLSConfig = &tls.Config{
			Certificates: []tls.Certificate{{
				Certificate: [][]byte{cert},
				PrivateKey:  key,
			}},
			MinVersion: tls.VersionTLS12,
		}
		log.Printf("Starting pcloudcc-webui on https://0.0.0.0%s", addr)
		log.Fatal(srv.ListenAndServeTLS("", ""))
	} else {
		log.Printf("Starting pcloudcc-webui on http://0.0.0.0%s", addr)
		fmt.Fprintln(os.Stderr, "WARNING: Running without TLS. Use a reverse proxy or set WEBUI_TLS=true for production.")
		log.Fatal(srv.ListenAndServe())
	}
}

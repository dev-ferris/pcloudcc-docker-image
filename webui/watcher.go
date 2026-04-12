package main

import (
	"encoding/json"
	"io"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// --- Status Watcher ---

// Status represents the current state of the pcloudcc container,
// read from the shared status.json file.
type Status struct {
	State          string `json:"state"`            // "setup_required", "running", "stopped"
	PID            int    `json:"pid"`              // pcloudcc process ID
	Mounted        bool   `json:"mounted"`          // whether the FUSE mount is active
	StartedAt      string `json:"started_at"`       // ISO 8601 timestamp
	CryptoUnlocked bool   `json:"crypto_unlocked"`  // whether the crypto folder is unlocked
	SetupDone      bool   `json:"-"`                // derived: data.db exists
}

type StatusWatcher struct {
	sharedDir string
	configDir string
	mu        sync.RWMutex
	status    Status
}

func NewStatusWatcher(sharedDir, configDir string) *StatusWatcher {
	return &StatusWatcher{
		sharedDir: sharedDir,
		configDir: configDir,
		status:    Status{State: "unknown"},
	}
}

func (sw *StatusWatcher) Run() {
	for {
		sw.update()
		time.Sleep(3 * time.Second)
	}
}

func (sw *StatusWatcher) update() {
	var s Status

	data, err := os.ReadFile(filepath.Join(sw.sharedDir, "status.json"))
	if err != nil {
		s.State = "unknown"
	} else if err := json.Unmarshal(data, &s); err != nil {
		s.State = "unknown"
	}

	// Check if data.db exists (setup completed).
	_, err = os.Stat(filepath.Join(sw.configDir, "data.db"))
	s.SetupDone = err == nil

	sw.mu.Lock()
	sw.status = s
	sw.mu.Unlock()
}

func (sw *StatusWatcher) Get() Status {
	sw.mu.RLock()
	defer sw.mu.RUnlock()
	return sw.status
}

// --- Log Tailer ---

// LogTailer tails a log file and fans out new lines to subscribers via channels.
type LogTailer struct {
	path string
	mu   sync.Mutex
	subs map[chan string]struct{}
	// Ring buffer of recent lines for new subscribers.
	ringMu sync.RWMutex
	ring   []string
}

const ringSize = 500

func NewLogTailer(path string) *LogTailer {
	return &LogTailer{
		path: path,
		subs: make(map[chan string]struct{}),
		ring: make([]string, 0, ringSize),
	}
}

func (lt *LogTailer) Run() {
	for {
		lt.tail()
		// If the file doesn't exist yet, retry.
		time.Sleep(2 * time.Second)
	}
}

func (lt *LogTailer) tail() {
	f, err := os.Open(lt.path)
	if err != nil {
		return
	}
	defer f.Close()

	// Seek to end.
	if _, err := f.Seek(0, io.SeekEnd); err != nil {
		return
	}

	buf := make([]byte, 4096)
	var partial string

	for {
		n, err := f.Read(buf)
		if n > 0 {
			text := partial + string(buf[:n])
			partial = ""

			lines := splitLines(text)
			// If text doesn't end with newline, last element is a partial line.
			if len(text) > 0 && text[len(text)-1] != '\n' {
				partial = lines[len(lines)-1]
				lines = lines[:len(lines)-1]
			}

			for _, line := range lines {
				if line == "" {
					continue
				}
				lt.addToRing(line)
				lt.broadcast(line)
			}
		}
		if err != nil {
			if err == io.EOF {
				time.Sleep(500 * time.Millisecond)
				continue
			}
			return
		}
	}
}

func splitLines(s string) []string {
	var lines []string
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '\n' {
			lines = append(lines, s[start:i])
			start = i + 1
		}
	}
	if start < len(s) {
		lines = append(lines, s[start:])
	}
	return lines
}

func (lt *LogTailer) addToRing(line string) {
	lt.ringMu.Lock()
	defer lt.ringMu.Unlock()
	if len(lt.ring) >= ringSize {
		lt.ring = lt.ring[1:]
	}
	lt.ring = append(lt.ring, line)
}

func (lt *LogTailer) broadcast(line string) {
	lt.mu.Lock()
	defer lt.mu.Unlock()
	for ch := range lt.subs {
		select {
		case ch <- line:
		default:
			// Slow subscriber, drop the line.
		}
	}
}

// Subscribe returns a channel that receives new log lines.
// The channel is pre-filled with the ring buffer contents.
func (lt *LogTailer) Subscribe() chan string {
	ch := make(chan string, ringSize+64)

	// Send ring buffer as backfill.
	lt.ringMu.RLock()
	for _, line := range lt.ring {
		ch <- line
	}
	lt.ringMu.RUnlock()

	lt.mu.Lock()
	lt.subs[ch] = struct{}{}
	lt.mu.Unlock()

	return ch
}

func (lt *LogTailer) Unsubscribe(ch chan string) {
	lt.mu.Lock()
	delete(lt.subs, ch)
	lt.mu.Unlock()
}

// --- Setup Manager ---

// SetupManager handles the file-based login protocol with the pcloudcc container.
type SetupManager struct {
	sharedDir string
	configDir string
}

func NewSetupManager(sharedDir, configDir string) *SetupManager {
	return &SetupManager{sharedDir: sharedDir, configDir: configDir}
}

// NeedsSetup returns true if data.db does not yet exist.
func (sm *SetupManager) NeedsSetup() bool {
	_, err := os.Stat(filepath.Join(sm.configDir, "data.db"))
	return err != nil
}

// RequestLogin writes the credential files and trigger for the entrypoint to pick up.
func (sm *SetupManager) RequestLogin(email, password, twofa string) error {
	if err := os.MkdirAll(sm.sharedDir, 0o755); err != nil {
		return err
	}

	// Write credential files.
	if err := os.WriteFile(filepath.Join(sm.sharedDir, "login-email"), []byte(email), 0o644); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(sm.sharedDir, "login-pass"), []byte(password), 0o600); err != nil {
		return err
	}
	if twofa != "" {
		if err := os.WriteFile(filepath.Join(sm.sharedDir, "login-2fa"), []byte(twofa), 0o644); err != nil {
			return err
		}
	}

	// Remove stale result.
	os.Remove(filepath.Join(sm.sharedDir, "login-result"))

	// Write trigger last — entrypoint watches for this.
	if err := os.WriteFile(filepath.Join(sm.sharedDir, "login-trigger"), []byte("1"), 0o644); err != nil {
		return err
	}

	return nil
}

// PollResult waits for the login result file to appear.
// Returns the result string and whether it was successful.
func (sm *SetupManager) PollResult(timeout time.Duration) (string, bool) {
	deadline := time.Now().Add(timeout)
	resultPath := filepath.Join(sm.sharedDir, "login-result")

	for time.Now().Before(deadline) {
		data, err := os.ReadFile(resultPath)
		if err == nil {
			result := string(data)
			// Clean up.
			os.Remove(resultPath)
			if result == "ok" || result == "ok\n" {
				return "Login successful. pcloudcc is starting up.", true
			}
			return result, false
		}
		time.Sleep(time.Second)
	}

	log.Println("Login result poll timed out")
	return "Timeout waiting for login result. Check container logs.", false
}

// --- Crypto Manager ---

// CryptoManager handles the file-based crypto unlock protocol
// with the pcloudcc container.
type CryptoManager struct {
	sharedDir string
}

func NewCryptoManager(sharedDir string) *CryptoManager {
	return &CryptoManager{sharedDir: sharedDir}
}

// RequestUnlock writes the crypto password and trigger for the entrypoint to pick up.
func (cm *CryptoManager) RequestUnlock(password string) error {
	if err := os.MkdirAll(cm.sharedDir, 0o755); err != nil {
		return err
	}

	if err := os.WriteFile(filepath.Join(cm.sharedDir, "crypto-pass"), []byte(password), 0o600); err != nil {
		return err
	}

	// Remove stale result.
	os.Remove(filepath.Join(cm.sharedDir, "crypto-result"))

	// Write trigger last.
	return os.WriteFile(filepath.Join(cm.sharedDir, "crypto-trigger"), []byte("1"), 0o644)
}

// PollResult waits for the crypto result file to appear.
func (cm *CryptoManager) PollResult(timeout time.Duration) (string, bool) {
	deadline := time.Now().Add(timeout)
	resultPath := filepath.Join(cm.sharedDir, "crypto-result")

	for time.Now().Before(deadline) {
		data, err := os.ReadFile(resultPath)
		if err == nil {
			result := string(data)
			os.Remove(resultPath)
			if result == "ok" || result == "ok\n" {
				return "Crypto folder unlocked successfully.", true
			}
			return result, false
		}
		time.Sleep(time.Second)
	}

	log.Println("Crypto result poll timed out")
	return "Timeout waiting for crypto unlock result. Check container logs.", false
}

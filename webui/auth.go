package main

import (
	"crypto/sha256"
	"crypto/subtle"
	"net/http"
)

// BasicAuth returns middleware that protects handlers with HTTP Basic Authentication.
// Uses constant-time comparison to prevent timing attacks.
func BasicAuth(username, password string) func(http.Handler) http.Handler {
	wantUser := sha256.Sum256([]byte(username))
	wantPass := sha256.Sum256([]byte(password))

	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			user, pass, ok := r.BasicAuth()
			if !ok {
				w.Header().Set("WWW-Authenticate", `Basic realm="pcloudcc-webui"`)
				http.Error(w, "Unauthorized", http.StatusUnauthorized)
				return
			}

			gotUser := sha256.Sum256([]byte(user))
			gotPass := sha256.Sum256([]byte(pass))

			userOK := subtle.ConstantTimeCompare(gotUser[:], wantUser[:]) == 1
			passOK := subtle.ConstantTimeCompare(gotPass[:], wantPass[:]) == 1

			if !userOK || !passOK {
				w.Header().Set("WWW-Authenticate", `Basic realm="pcloudcc-webui"`)
				http.Error(w, "Unauthorized", http.StatusUnauthorized)
				return
			}

			next.ServeHTTP(w, r)
		})
	}
}

package platform

import (
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	SessionCookie = "fleet_session"
	tokenIssuer   = "rbac-authz"
)

type Claims struct {
	Name string `json:"name"`
	Role string `json:"role"`
	jwt.RegisteredClaims
}

func IssueToken(key []byte, userID, name, role string, ttl time.Duration) (string, time.Time, error) {
	exp := time.Now().Add(ttl)
	c := Claims{
		Name: name,
		Role: role,
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   userID,
			Issuer:    tokenIssuer,
			IssuedAt:  jwt.NewNumericDate(time.Now()),
			ExpiresAt: jwt.NewNumericDate(exp),
		},
	}
	s, err := jwt.NewWithClaims(jwt.SigningMethodHS256, c).SignedString(key)
	return s, exp, err
}

func ParseToken(key []byte, token string) (*Claims, error) {
	c := &Claims{}
	_, err := jwt.ParseWithClaims(token, c, func(*jwt.Token) (any, error) { return key, nil },
		jwt.WithValidMethods([]string{"HS256"}), jwt.WithIssuer(tokenIssuer), jwt.WithExpirationRequired())
	if err != nil {
		return nil, err
	}
	if c.Subject == "" {
		return nil, errors.New("token has no subject")
	}
	return c, nil
}

// TokenFromRequest accepts "Authorization: Bearer <jwt>" or the HttpOnly session cookie
// (browsers' EventSource cannot set headers, so SSE relies on the cookie).
func TokenFromRequest(r *http.Request) string {
	if h := r.Header.Get("Authorization"); strings.HasPrefix(h, "Bearer ") {
		return strings.TrimPrefix(h, "Bearer ")
	}
	if c, err := r.Cookie(SessionCookie); err == nil {
		return c.Value
	}
	return ""
}

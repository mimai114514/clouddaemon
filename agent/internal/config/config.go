package config

import (
	"errors"
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

type Config struct {
	ListenAddr          string   `yaml:"listen_addr"`
	TLSCertFile         string   `yaml:"tls_cert_file"`
	TLSKeyFile          string   `yaml:"tls_key_file"`
	AdminToken          string   `yaml:"admin_token"`
	AllowedOrigins      []string `yaml:"allowed_origins"`
	LogTailDefaultLines int      `yaml:"log_tail_default_lines"`
}

func Load(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("read config: %w", err)
	}

	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return Config{}, fmt.Errorf("parse config yaml: %w", err)
	}

	if cfg.LogTailDefaultLines == 0 {
		cfg.LogTailDefaultLines = 200
	}

	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}

	return cfg, nil
}

func (c Config) Validate() error {
	switch {
	case c.ListenAddr == "":
		return errors.New("listen_addr is required")
	case c.TLSCertFile == "":
		return errors.New("tls_cert_file is required")
	case c.TLSKeyFile == "":
		return errors.New("tls_key_file is required")
	case c.AdminToken == "":
		return errors.New("admin_token is required")
	case len(c.AllowedOrigins) == 0:
		return errors.New("allowed_origins must contain at least one origin")
	case c.LogTailDefaultLines < 0:
		return errors.New("log_tail_default_lines must be >= 0")
	default:
		return nil
	}
}

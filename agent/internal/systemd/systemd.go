package systemd

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"regexp"
	"slices"
	"strconv"
	"strings"
)

var serviceNamePattern = regexp.MustCompile(`^[A-Za-z0-9@_.:-]+\.service$`)

type Service struct {
	UnitName    string `json:"unit_name"`
	Description string `json:"description"`
	LoadState   string `json:"load_state"`
	ActiveState string `json:"active_state"`
	SubState    string `json:"sub_state"`
	StatusText  string `json:"status_text,omitempty"`
	CanStart    bool   `json:"can_start"`
	CanStop     bool   `json:"can_stop"`
	CanRestart  bool   `json:"can_restart"`
}

type LogEntry struct {
	Service string `json:"service"`
	Line    string `json:"line"`
	TS      string `json:"ts"`
}

type Runner interface {
	Run(ctx context.Context, name string, args ...string) ([]byte, error)
	Start(ctx context.Context, name string, args ...string) (io.ReadCloser, func() error, error)
}

type ExecRunner struct{}

func NewExecRunner() ExecRunner {
	return ExecRunner{}
}

func (ExecRunner) Run(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	return cmd.CombinedOutput()
}

func (ExecRunner) Start(ctx context.Context, name string, args ...string) (io.ReadCloser, func() error, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, nil, err
	}
	cmd.Stderr = cmd.Stdout
	if err := cmd.Start(); err != nil {
		return nil, nil, err
	}
	return stdout, cmd.Wait, nil
}

type Manager struct {
	runner Runner
}

func NewManager(runner Runner) *Manager {
	return &Manager{runner: runner}
}

func ValidateServiceName(serviceName string) error {
	if !serviceNamePattern.MatchString(serviceName) {
		return fmt.Errorf("invalid service name %q", serviceName)
	}
	return nil
}

func (m *Manager) SystemdAvailable(ctx context.Context) bool {
	_, err := m.runner.Run(ctx, "systemctl", "--version")
	return err == nil
}

func (m *Manager) ListServices(ctx context.Context, query string) ([]Service, error) {
	output, err := m.runner.Run(
		ctx,
		"systemctl",
		"list-units",
		"--type=service",
		"--all",
		"--plain",
		"--no-pager",
		"--no-legend",
	)
	if err != nil {
		return nil, fmt.Errorf("list services: %w: %s", err, strings.TrimSpace(string(output)))
	}

	services, err := ParseListUnits(string(output))
	if err != nil {
		return nil, err
	}

	if query == "" {
		return services, nil
	}

	query = strings.ToLower(query)
	filtered := make([]Service, 0, len(services))
	for _, service := range services {
		if strings.Contains(strings.ToLower(service.UnitName), query) ||
			strings.Contains(strings.ToLower(service.Description), query) {
			filtered = append(filtered, service)
		}
	}
	return filtered, nil
}

func (m *Manager) GetService(ctx context.Context, serviceName string) (Service, error) {
	if err := ValidateServiceName(serviceName); err != nil {
		return Service{}, err
	}
	if err := m.ensureServiceExists(ctx, serviceName); err != nil {
		return Service{}, err
	}

	output, err := m.runner.Run(
		ctx,
		"systemctl",
		"show",
		serviceName,
		"--property=Id",
		"--property=Description",
		"--property=LoadState",
		"--property=ActiveState",
		"--property=SubState",
		"--property=CanStart",
		"--property=CanStop",
		"--property=StatusText",
	)
	if err != nil {
		return Service{}, fmt.Errorf("show service: %w: %s", err, strings.TrimSpace(string(output)))
	}

	return ParseShowOutput(string(output)), nil
}

func (m *Manager) Action(ctx context.Context, serviceName, action string) (Service, error) {
	if err := ValidateServiceName(serviceName); err != nil {
		return Service{}, err
	}
	if !slices.Contains([]string{"start", "stop", "restart"}, action) {
		return Service{}, fmt.Errorf("invalid action %q", action)
	}
	if err := m.ensureServiceExists(ctx, serviceName); err != nil {
		return Service{}, err
	}

	output, err := m.runner.Run(ctx, "systemctl", action, serviceName)
	if err != nil {
		return Service{}, fmt.Errorf("systemctl %s: %w: %s", action, err, strings.TrimSpace(string(output)))
	}

	return m.GetService(ctx, serviceName)
}

func (m *Manager) RecentLogs(ctx context.Context, serviceName string, lines int) ([]LogEntry, error) {
	if err := ValidateServiceName(serviceName); err != nil {
		return nil, err
	}
	if err := m.ensureServiceExists(ctx, serviceName); err != nil {
		return nil, err
	}
	if lines <= 0 {
		lines = 200
	}

	output, err := m.runner.Run(
		ctx,
		"journalctl",
		"-u",
		serviceName,
		"-n",
		strconv.Itoa(lines),
		"--no-pager",
		"-o",
		"short-iso",
	)
	if err != nil {
		return nil, fmt.Errorf("recent logs: %w: %s", err, strings.TrimSpace(string(output)))
	}

	entries := make([]LogEntry, 0)
	scanner := bufio.NewScanner(strings.NewReader(string(output)))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		entries = append(entries, splitLogLine(serviceName, line))
	}
	return entries, scanner.Err()
}

func (m *Manager) FollowLogs(ctx context.Context, serviceName string) (<-chan LogEntry, <-chan error, func() error, error) {
	if err := ValidateServiceName(serviceName); err != nil {
		return nil, nil, nil, err
	}
	if err := m.ensureServiceExists(ctx, serviceName); err != nil {
		return nil, nil, nil, err
	}

	reader, waitFn, err := m.runner.Start(
		ctx,
		"journalctl",
		"-u",
		serviceName,
		"-f",
		"-n",
		"0",
		"-o",
		"short-iso",
	)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("follow logs: %w", err)
	}

	entryCh := make(chan LogEntry)
	errCh := make(chan error, 1)
	stopFn := func() error {
		if closer, ok := reader.(io.Closer); ok {
			_ = closer.Close()
		}
		return nil
	}

	go func() {
		defer close(entryCh)
		defer close(errCh)

		scanner := bufio.NewScanner(reader)
		for scanner.Scan() {
			select {
			case <-ctx.Done():
				return
			case entryCh <- splitLogLine(serviceName, scanner.Text()):
			}
		}

		if err := scanner.Err(); err != nil && !errors.Is(err, io.EOF) {
			errCh <- err
			return
		}

		if err := waitFn(); err != nil && !errors.Is(err, io.EOF) {
			errCh <- err
		}
	}()

	return entryCh, errCh, stopFn, nil
}

func (m *Manager) ensureServiceExists(ctx context.Context, serviceName string) error {
	services, err := m.ListServices(ctx, "")
	if err != nil {
		return err
	}
	for _, service := range services {
		if service.UnitName == serviceName {
			return nil
		}
	}
	return fmt.Errorf("service %q is not available", serviceName)
}

func ParseListUnits(output string) ([]Service, error) {
	services := make([]Service, 0)
	scanner := bufio.NewScanner(strings.NewReader(output))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		parts := strings.Fields(line)
		if len(parts) < 5 {
			return nil, fmt.Errorf("unexpected list-units line: %q", line)
		}

		service := Service{
			UnitName:    parts[0],
			LoadState:   parts[1],
			ActiveState: parts[2],
			SubState:    parts[3],
			Description: strings.Join(parts[4:], " "),
		}
		service.CanStart = service.ActiveState != "active" || service.SubState != "running"
		service.CanStop = service.ActiveState == "active" || service.ActiveState == "activating"
		service.CanRestart = service.CanStop
		services = append(services, service)
	}
	return services, scanner.Err()
}

func ParseShowOutput(output string) Service {
	values := map[string]string{}
	scanner := bufio.NewScanner(strings.NewReader(output))
	for scanner.Scan() {
		line := scanner.Text()
		key, value, ok := strings.Cut(line, "=")
		if ok {
			values[key] = value
		}
	}

	service := Service{
		UnitName:    values["Id"],
		Description: values["Description"],
		LoadState:   values["LoadState"],
		ActiveState: values["ActiveState"],
		SubState:    values["SubState"],
		StatusText:  values["StatusText"],
		CanStart:    values["CanStart"] == "yes",
		CanStop:     values["CanStop"] == "yes",
	}
	service.CanRestart = service.CanStop || service.ActiveState == "activating"
	return service
}

func splitLogLine(serviceName, line string) LogEntry {
	ts := ""
	message := line
	if len(line) > len("2006-01-02 15:04:05") {
		if idx := strings.IndexByte(line, ' '); idx > 0 {
			if idx2 := strings.IndexByte(line[idx+1:], ' '); idx2 >= 0 {
				absoluteIdx := idx + idx2 + 1
				ts = strings.TrimSpace(line[:absoluteIdx])
				message = strings.TrimSpace(line[absoluteIdx:])
			}
		}
	}

	return LogEntry{
		Service: serviceName,
		TS:      ts,
		Line:    message,
	}
}

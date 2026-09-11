package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
	"syscall"
	"unicode"
)

type config struct {
	kubectlPath string
	dqRoot      string
	bashPath    string
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		deny("wrapper configuration error", err.Error())
	}

	original := strings.TrimSpace(os.Getenv("SSH_ORIGINAL_COMMAND"))
	logAttempt(original)

	if original == "" {
		deny("interactive shell access not permitted", "interactive")
	}

	argv, err := splitCommand(original)
	if err != nil {
		deny("unable to parse SSH_ORIGINAL_COMMAND", original)
	}

	execPath, execArgs, err := planCommand(cfg, argv)
	if err != nil {
		deny(err.Error(), original)
	}

	if err := syscall.Exec(execPath, execArgs, os.Environ()); err != nil {
		deny(fmt.Sprintf("unable to execute allowed command: %v", err), original)
	}
}

func loadConfig() (config, error) {
	var cfg config

	flag.StringVar(&cfg.kubectlPath, "kubectl", "/usr/local/bin/kubectl", "absolute path to the allowed kubectl binary")
	flag.StringVar(&cfg.dqRoot, "dq-root", "", "absolute path to the dq-made-easy checkout that contains approved validation scripts")
	flag.Parse()

	bashPath, err := exec.LookPath("bash")
	if err != nil {
		return config{}, fmt.Errorf("locate bash: %w", err)
	}

	kubectlPath, err := filepath.Abs(cfg.kubectlPath)
	if err != nil {
		return config{}, fmt.Errorf("normalize kubectl path: %w", err)
	}

	cfg.kubectlPath = kubectlPath
	cfg.bashPath = bashPath

	if cfg.dqRoot != "" {
		resolvedRoot, err := resolvePath(cfg.dqRoot)
		if err != nil {
			return config{}, fmt.Errorf("resolve dq-root: %w", err)
		}
		cfg.dqRoot = resolvedRoot
	}

	return cfg, nil
}

func planCommand(cfg config, argv []string) (string, []string, error) {
	if len(argv) == 0 {
		return "", nil, errors.New("empty command")
	}

	if kubectlExecPath, ok, err := resolveKubectl(cfg.kubectlPath, argv[0]); err != nil {
		return "", nil, err
	} else if ok {
		return kubectlExecPath, append([]string{kubectlExecPath}, argv[1:]...), nil
	}

	if bashExecPath, ok, err := resolveBash(cfg.bashPath, argv[0]); err != nil {
		return "", nil, err
	} else if ok {
		if len(argv) < 2 {
			return "", nil, errors.New("bash requires a script path")
		}
		if strings.HasPrefix(argv[1], "-") {
			return "", nil, errors.New("bash flags are not allowed")
		}

		scriptPath, err := resolvePath(argv[1])
		if err != nil {
			return "", nil, fmt.Errorf("resolve script path: %w", err)
		}
		if !isAllowedValidationScript(cfg.dqRoot, scriptPath) {
			return "", nil, fmt.Errorf("command not allowed: %s", strings.Join(argv, " "))
		}

		execArgs := []string{bashExecPath, scriptPath}
		execArgs = append(execArgs, argv[2:]...)
		return bashExecPath, execArgs, nil
	}

	return "", nil, fmt.Errorf("command not allowed: %s", strings.Join(argv, " "))
}

func resolveKubectl(expectedPath, requested string) (string, bool, error) {
	if requested == expectedPath {
		return requested, true, nil
	}

	if requested != "kubectl" {
		return "", false, nil
	}

	resolvedRequested, err := exec.LookPath(requested)
	if err != nil {
		return "", false, fmt.Errorf("locate kubectl: %w", err)
	}

	canonicalExpected, err := resolvePath(expectedPath)
	if err != nil {
		return "", false, fmt.Errorf("resolve kubectl path: %w", err)
	}

	canonicalRequested, err := resolvePath(resolvedRequested)
	if err != nil {
		return "", false, fmt.Errorf("resolve kubectl executable: %w", err)
	}

	if canonicalExpected != canonicalRequested {
		return "", false, fmt.Errorf("kubectl path mismatch: expected %s, got %s", canonicalExpected, canonicalRequested)
	}

	return canonicalRequested, true, nil
}

func resolveBash(expectedPath, requested string) (string, bool, error) {
	if requested == expectedPath {
		return requested, true, nil
	}

	if requested != "bash" {
		return "", false, nil
	}

	resolvedRequested, err := exec.LookPath(requested)
	if err != nil {
		return "", false, fmt.Errorf("locate bash: %w", err)
	}

	canonicalExpected, err := resolvePath(expectedPath)
	if err != nil {
		return "", false, fmt.Errorf("resolve bash path: %w", err)
	}

	canonicalRequested, err := resolvePath(resolvedRequested)
	if err != nil {
		return "", false, fmt.Errorf("resolve bash executable: %w", err)
	}

	if canonicalExpected != canonicalRequested {
		return "", false, fmt.Errorf("bash path mismatch: expected %s, got %s", canonicalExpected, canonicalRequested)
	}

	return canonicalRequested, true, nil
}

func isAllowedValidationScript(dqRoot, scriptPath string) bool {
	if dqRoot == "" {
		return false
	}

	scriptsRoot := filepath.Join(dqRoot, "scripts")
	relPath, err := filepath.Rel(scriptsRoot, scriptPath)
	if err != nil {
		return false
	}

	if relPath == ".." || strings.HasPrefix(relPath, ".."+string(os.PathSeparator)) {
		return false
	}

	fileName := filepath.Base(relPath)
	if fileName == "." || !strings.HasSuffix(fileName, ".sh") {
		return false
	}

	dirName := filepath.Dir(relPath)
	if dirName == "." {
		return strings.HasPrefix(fileName, "validate")
	}

	return dirName == "validation" || strings.HasPrefix(dirName, "validation"+string(os.PathSeparator))
}

func resolvePath(path string) (string, error) {
	absPath, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}

	resolvedPath, err := filepath.EvalSymlinks(absPath)
	if err != nil {
		return "", err
	}

	return resolvedPath, nil
}

func splitCommand(input string) ([]string, error) {
	args := make([]string, 0, 8)
	var current strings.Builder
	tokenStarted := false
	inSingleQuotes := false
	inDoubleQuotes := false
	escaped := false

	flush := func() {
		args = append(args, current.String())
		current.Reset()
		tokenStarted = false
	}

	for _, char := range input {
		switch {
		case escaped:
			if char == '\n' || char == '\r' {
				return nil, errors.New("newline escapes are not supported")
			}
			current.WriteRune(char)
			tokenStarted = true
			escaped = false
		case inSingleQuotes:
			if char == '\'' {
				inSingleQuotes = false
			} else {
				if unicode.IsControl(char) {
					return nil, errors.New("control characters are not allowed")
				}
				current.WriteRune(char)
				tokenStarted = true
			}
		case inDoubleQuotes:
			switch char {
			case '"':
				inDoubleQuotes = false
			case '\\':
				escaped = true
			default:
				if unicode.IsControl(char) {
					return nil, errors.New("control characters are not allowed")
				}
				current.WriteRune(char)
				tokenStarted = true
			}
		default:
			switch {
			case char == '\\':
				escaped = true
				tokenStarted = true
			case char == '\'':
				inSingleQuotes = true
				tokenStarted = true
			case char == '"':
				inDoubleQuotes = true
				tokenStarted = true
			case unicode.IsSpace(char):
				if tokenStarted {
					flush()
				}
			case unicode.IsControl(char):
				return nil, errors.New("control characters are not allowed")
			default:
				current.WriteRune(char)
				tokenStarted = true
			}
		}
	}

	if escaped || inSingleQuotes || inDoubleQuotes {
		return nil, errors.New("unterminated escape or quote")
	}

	if tokenStarted {
		flush()
	}

	if len(args) == 0 {
		return nil, errors.New("empty command")
	}

	return args, nil
}

func logAttempt(command string) {
	displayCommand := command
	if displayCommand == "" {
		displayCommand = "interactive"
	}

	userName := os.Getenv("USER")
	if userName == "" {
		if currentUser, err := user.Current(); err == nil {
			userName = currentUser.Username
		}
	}

	message := fmt.Sprintf("SSH restricted access: user=%s command=%s", userName, displayCommand)
	if loggerPath, err := exec.LookPath("logger"); err == nil {
		_ = exec.Command(loggerPath, message).Run()
	}
}

func deny(reason, command string) {
	fmt.Fprintln(os.Stderr, reason)
	if loggerPath, err := exec.LookPath("logger"); err == nil {
		_ = exec.Command(loggerPath, fmt.Sprintf("SSH restricted access denied: %s command=%s", reason, command)).Run()
	}
	os.Exit(1)
}
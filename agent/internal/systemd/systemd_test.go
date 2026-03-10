package systemd

import "testing"

func TestValidateServiceName(t *testing.T) {
	valid := []string{"nginx.service", "docker.service", "ssh@22.service"}
	for _, name := range valid {
		if err := ValidateServiceName(name); err != nil {
			t.Fatalf("ValidateServiceName(%q) = %v", name, err)
		}
	}

	invalid := []string{"nginx", "../nginx.service", "bad service.service"}
	for _, name := range invalid {
		if err := ValidateServiceName(name); err == nil {
			t.Fatalf("ValidateServiceName(%q) expected error", name)
		}
	}
}

func TestParseListUnits(t *testing.T) {
	output := "nginx.service loaded active running A high performance web server\n" +
		"docker.service loaded inactive dead Docker Application Container Engine\n"

	services, err := ParseListUnits(output)
	if err != nil {
		t.Fatalf("ParseListUnits() error = %v", err)
	}
	if len(services) != 2 {
		t.Fatalf("expected 2 services, got %d", len(services))
	}
	if services[0].UnitName != "nginx.service" || services[0].SubState != "running" {
		t.Fatalf("unexpected first service: %+v", services[0])
	}
	if !services[0].CanRestart || services[1].CanStop {
		t.Fatalf("unexpected action flags: %+v %+v", services[0], services[1])
	}
}

func TestParseShowOutput(t *testing.T) {
	output := "Id=nginx.service\nDescription=NGINX\nLoadState=loaded\nActiveState=active\nSubState=running\nCanStart=yes\nCanStop=yes\nStatusText=healthy\n"
	service := ParseShowOutput(output)
	if service.UnitName != "nginx.service" {
		t.Fatalf("unexpected service name: %+v", service)
	}
	if !service.CanStart || !service.CanStop || !service.CanRestart {
		t.Fatalf("unexpected action flags: %+v", service)
	}
}

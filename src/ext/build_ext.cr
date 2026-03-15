def cmd(cmd, args, chdir)
  puts "--- '#{cmd} #{args.join(" ")}' (in #{chdir}) ---"

  Process.run(cmd, args: args, chdir: chdir.to_s, input: Process::Redirect::Inherit, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)

  if $?.exit_code != 0
    puts "Failed with status #{$?.exit_code}"
    exit $?.exit_code
  end
end

def download_file(url, output_path)
  puts "--- Downloading #{url} to #{output_path} ---"

  {% if flag?(:win32) %}
    if system("where curl > nul 2>&1")
      cmd("curl", ["-L", url, "-o", output_path.to_s], Dir.current)
    elsif system("where wget > nul 2>&1")
      cmd("wget", ["-O", output_path.to_s, url], Dir.current)
    elsif system("where powershell > nul 2>&1")
      ps_command = "Invoke-WebRequest -Uri '#{url}' -OutFile '#{output_path}'"
      cmd("powershell", ["-Command", ps_command], Dir.current)
    else
      puts "Error: No download tool found. Please install curl or wget."
      exit 1
    end
  {% else %}
    if system("command -v curl > /dev/null 2>&1")
      cmd("curl", ["-L", url, "-o", output_path.to_s], Dir.current)
    elsif system("command -v wget > /dev/null 2>&1")
      cmd("wget", ["-O", output_path.to_s, url], Dir.current)
    elsif system("command -v fetch > /dev/null 2>&1")
      cmd("fetch", ["-o", output_path.to_s, url], Dir.current)
    else
      puts "Error: No download tool found. Please install curl or wget."
      exit 1
    end
  {% end %}
end

def compile_windows(source_path, output_path)
  fixed_source = output_path / "lxb_fixed.c"
  content = File.read(source_path)
  content = content.gsub("#include <dirent.h>", "// #include <dirent.h>")

  fixes = <<-FIXES
#define _CRT_SECURE_NO_WARNINGS
#define _WINSOCK_DEPRECATED_NO_WARNINGS

#ifdef _MSC_VER
#include <windows.h>
#include <io.h>
#include <stdlib.h>
#include <string.h>

struct dirent {
    char d_name[260];
};

typedef struct DIR {
    intptr_t handle;
    struct _finddata_t data;
    struct dirent ent;
    int first;
} DIR;

DIR *opendir(const char *path) {
    DIR *dir = (DIR*)malloc(sizeof(DIR));
    if (!dir) return NULL;
    
    char search_path[1024];
    snprintf(search_path, sizeof(search_path), "%s/*", path);
    
    dir->handle = _findfirst(search_path, &dir->data);
    dir->first = 1;
    
    if (dir->handle == -1) {
        free(dir);
        return NULL;
    }
    
    return dir;
}

struct dirent *readdir(DIR *dir) {
    if (!dir) return NULL;
    
    if (dir->first) {
        dir->first = 0;
    } else {
        if (_findnext(dir->handle, &dir->data) != 0) {
            return NULL;
        }
    }
    
    strncpy(dir->ent.d_name, dir->data.name, sizeof(dir->ent.d_name) - 1);
    dir->ent.d_name[sizeof(dir->ent.d_name) - 1] = '\\0';
    
    return &dir->ent;
}

int closedir(DIR *dir) {
    if (!dir) return -1;
    _findclose(dir->handle);
    free(dir);
    return 0;
}
#endif

FIXES

  File.write(fixed_source, fixes + content)

  compile_cmd = ENV["CC"]? || "cl"
  compile_args = [
    "/nologo",
    "/O2",
    "/c",
    fixed_source.to_s,
    "/Fo#{output_path}/lxb.obj",
  ]

  if env_flags = ENV["CFLAGS"]?
    compile_args += env_flags.split
  end

  cmd(compile_cmd, compile_args, Dir.current)

  lib_cmd = ENV["LIB"]? || "lib"
  lib_args = [
    "/nologo",
    "/out:#{output_path}/lexbor_static.lib",
    "#{output_path}/lxb.obj",
  ]

  if env_lflags = ENV["LDFLAGS"]?
    lib_args += env_lflags.split
  end

  cmd(lib_cmd, lib_args, Dir.current)

  link_cmd = ENV["LD"]? || "link"
  dll_args = [
    "/nologo",
    "/DLL",
    "/out:#{output_path}/lxb.dll",
    "#{output_path}/lxb.obj",
  ]

  if env_lflags = ENV["LDFLAGS"]?
    dll_args += env_lflags.split
  end

  cmd(link_cmd, dll_args, Dir.current)

  puts "--- Removing temporary files ---"
  File.delete("#{output_path}/lxb.obj") if File.exists?("#{output_path}/lxb.obj")
  File.delete(fixed_source) if File.exists?(fixed_source)
  File.delete(source_path) if File.exists?(source_path)

  puts "--- Static library created: #{output_path}/lexbor_static.lib ---"
  puts "--- Dynamic library created: #{output_path}/lxb.dll ---"
end

def compile_unix(source_path, output_path)
  compile_cmd = ENV["CC"]? || "cc"
  compile_args = [
    "-O3",
    "-c",
    source_path.to_s,
    "-o", "#{output_path}/lxb.o",
    "-fPIC",
  ]

  if env_flags = ENV["CFLAGS"]?
    compile_args += env_flags.split
  end

  cmd(compile_cmd, compile_args, Dir.current)

  ar_cmd = ENV["AR"]? || "ar"
  ar_args = [
    "rcs",
    "#{output_path}/liblxb.a",
    "#{output_path}/lxb.o",
  ]

  if env_arflags = ENV["ARFLAGS"]?
    ar_args += env_arflags.split
  end

  cmd(ar_cmd, ar_args, Dir.current)

  ld_cmd = ENV["LD"]? || compile_cmd
  so_args = [
    "-shared",
    "-o", "#{output_path}/liblxb.so",
    "#{output_path}/lxb.o",
  ]

  {% if flag?(:darwin) %}
    so_args = [
      "-shared",
      "-o", "#{output_path}/liblxb.dylib",
      "#{output_path}/lxb.o",
    ]
  {% end %}

  if env_lflags = ENV["LDFLAGS"]?
    so_args += env_lflags.split
  end

  cmd(ld_cmd, so_args, Dir.current)

  puts "--- Removing temporary files ---"
  File.delete("#{output_path}/lxb.o") if File.exists?("#{output_path}/lxb.o")
  File.delete(source_path) if File.exists?(source_path)

  puts "--- Static library created: #{output_path}/liblxb.a ---"
  {% if flag?(:darwin) %}
    puts "--- Dynamic library created: #{output_path}/liblxb.dylib ---"
  {% else %}
    puts "--- Dynamic library created: #{output_path}/liblxb.so ---"
  {% end %}
end

current_dir = Path[__FILE__].parent
ext_dir = current_dir / "lxb"

Dir.mkdir(ext_dir) unless File.directory?(ext_dir)

revision_file = current_dir / "revision"
if File.exists?(revision_file)
  version = File.read(revision_file).strip
else
  version = "v2.7.0"
end

amalgamation_url = "https://lexbor.com/api/amalgamation?version=#{version}&modules=core%2Ccss%2Cencoding%2Chtml%2Cselectors&ext=c"
amalgamation_file = ext_dir / "lxb.c"

download_file(amalgamation_url, amalgamation_file)

{% if flag?(:win32) %}
  compile_windows(amalgamation_file, ext_dir)
{% else %}
  compile_unix(amalgamation_file, ext_dir)
{% end %}

puts "--- Build completed successfully ---"

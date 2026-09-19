softwareinstaller_sources = [
  'main.vala',
  'application.vala',
  'window.vala',
]

softwareinstaller_deps = [
  config_dep,
  dependency('gtk4'),
  dependency('gdk-pixbuf-2.0'),
  dependency('libadwaita-1', version: '>= 1.4'),
  meson.get_compiler('vala').find_library('posix'),
]

softwareinstaller_sources += gnome.compile_resources('softwareinstaller-resources',
  'softwareinstaller.gresource.xml',
  c_name: 'softwareinstaller'
)

executable('softwareinstaller', softwareinstaller_sources,
  dependencies: softwareinstaller_deps,
  include_directories: config_inc,
       install: true,
)
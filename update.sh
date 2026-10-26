#!/bin/bash
if [ -f src/cf/.project ]; then
  echo "EDT sources require EDT-to-XML conversion. See doc/EDT-INITIALIZATION.md." >&2
  exit 2
fi

# обновление конфигурации основной разработческой ИБ без поддержки или на поддержке. по умолчанию в каталоге build/ib
vrunner update-dev --src src/cf --disable-support

# обновление конфигурации основной разработческой ИБ из хранилища. для включения раскомментируйте код ниже
# vrunner loadrepo "$@"
# vrunner updatedb "$@"

# собрать внешние обработчики и отчеты в каталоге build
# vrunner compileepf src/epf/МояВнешняяОбработка build "$@"
# vrunner compileepf src/erf/МойВнешнийОтчет build "$@"

# собрать расширения конфигурации внутри ИБ
# vrunner compileext src/cfe/МоеРасширение МоеРасширение "$@"

# обновление в режиме Предприятие
vrunner run --command "ЗапуститьОбновлениеИнформационнойБазы;ЗавершитьРаботуСистемы;" \
 --execute \$runnerRoot\epf\ЗакрытьПредприятие.epf "$@"

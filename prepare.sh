#!/bin/bash
if [ -f src/cf/.project ]; then
  echo "EDT sources require EDT-to-XML conversion. See doc/EDT-INITIALIZATION.md." >&2
  exit 2
fi

# Сборка основной разработческой ИБ. по умолчанию в каталоге build/ib
vrunner init-dev --src src/cf "$@"

# собрать внешние обработчики и отчеты в каталоге build
# vrunner compileepf src/epf/МояВнешняяОбработка build "$@"
# vrunner compileepf src/erf/МойВнешнийОтчет build "$@"

# собрать расширения конфигурации внутри ИБ
# vrunner compileext src/cfe/МоеРасширение МоеРасширение "$@"

# Обновление в режиме Предприятия
vrunner run --command "ЗапуститьОбновлениеИнформационнойБазы;ЗавершитьРаботуСистемы;" \
 --execute \$runnerRoot/epf/ЗакрытьПредприятие.epf "$@"

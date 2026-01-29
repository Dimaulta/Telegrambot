let tg = window.Telegram.WebApp;

// Перехватываем console.log для отправки на сервер
const originalConsoleLog = console.log;
const originalConsoleError = console.error;
const originalConsoleWarn = console.warn;

function sendLogToServer(level, ...args) {
    try {
        const message = args.map(arg => {
            if (typeof arg === 'object') {
                try {
                    return JSON.stringify(arg);
                } catch {
                    return String(arg);
                }
            }
            return String(arg);
        }).join(' ');
        
        // Отправляем на сервер асинхронно, не ждём ответа
        fetch('/api/log', {
            method: 'POST',
            headers: { 'Content-Type': 'text/plain' },
            body: `[${level}] ${message}`
        }).catch(() => {}); // Игнорируем ошибки отправки логов
    } catch (e) {
        // Игнорируем ошибки при логировании
    }
}

console.log = function(...args) {
    originalConsoleLog.apply(console, args);
    sendLogToServer('LOG', ...args);
};

console.error = function(...args) {
    originalConsoleError.apply(console, args);
    sendLogToServer('ERROR', ...args);
};

console.warn = function(...args) {
    originalConsoleWarn.apply(console, args);
    sendLogToServer('WARN', ...args);
};

// Состояние приложения
let isDragging = false;
let startX = 0;
let startY = 0;
let currentX = 0;
let currentY = 0;
let currentScale = 1;
let startDistance = 0;
let pinchStartScale = 1;
let minScaleGlobal = 1;
const MAX_SCALE = 4.0; // Увеличен для горизонтального видео
let anchorLocalX = 0;
let anchorLocalY = 0;
let videoFile = null;
let lastTouchTime = 0;
let lastScale = 1;
let pinchStartX = 0;
let pinchStartY = 0;
let videoContainerElem = null;
let persistentFileInput = null; // Постоянный скрытый input для выбора видео
const ELASTICITY = 0.4; // коэффициент упругости при выходе за границы (увеличен для более заметного эффекта)

// Элементы интерфейса (инициализируем после загрузки DOM)
let selectScreen, cropScreen, selectButton, videoPreview, cropFrame, playPauseButton, timeSlider, cropButton;

function initializeElements() {
    selectScreen = document.getElementById('select-screen');
    cropScreen = document.getElementById('crop-screen');
    selectButton = document.getElementById('select-video');
    videoPreview = document.getElementById('video-preview');
    cropFrame = document.querySelector('.crop-frame');
    playPauseButton = document.getElementById('play-pause');
    timeSlider = document.getElementById('time-slider');
    cropButton = document.getElementById('crop-video');
    
    console.log('Элементы интерфейса инициализированы:', {
        selectScreen: !!selectScreen,
        cropScreen: !!cropScreen,
        selectButton: !!selectButton,
        videoPreview: !!videoPreview,
        cropFrame: !!cropFrame,
        playPauseButton: !!playPauseButton,
        timeSlider: !!timeSlider,
        cropButton: !!cropButton
    });

    // Кнопка выбора должна быть контейнером для input
    if (selectButton) {
        selectButton.style.position = 'relative';
        selectButton.style.overflow = 'hidden';
    }
}

// Гарантированно создаём один скрытый input[type=file] и переиспользуем.
// Если есть кнопка выбора, встраиваем input внутрь кнопки, чтобы тап шёл прямо по input.
function ensureFileInput() {
    if (persistentFileInput) {
        const isInDOM = document.body.contains(persistentFileInput) || 
                       (selectButton && selectButton.contains(persistentFileInput));
        if (isInDOM) {
            console.log('Используем существующий persistentFileInput');
            return persistentFileInput;
        } else {
            console.log('persistentFileInput существует, но не в DOM, пересоздаём');
        }
    }
    
    console.log('Создаём новый input для выбора файла');
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = 'video/*';
    input.style.position = 'absolute';
    input.style.inset = '0';
    input.style.width = '100%';
    input.style.height = '100%';
    input.style.opacity = '0';
    input.style.cursor = 'pointer';
    input.style.zIndex = '10'; // Убеждаемся, что input поверх кнопки
    input.setAttribute('tabindex', '0');
    input.setAttribute('aria-label', 'Выбрать видео');
    
    if (selectButton) {
        console.log('Добавляем input внутрь кнопки selectButton');
        selectButton.appendChild(input);
    } else {
        console.log('selectButton не найден, добавляем input в body');
        document.body.appendChild(input);
    }

    input.addEventListener('change', (e) => {
        const file = e.target.files && e.target.files[0];
        console.log('persistentFileInput change fired, file:', file?.name, 'размер:', file?.size);
        if (file) {
            handleVideoSelect(file);
        } else {
            console.warn('Файл не выбран или пуст');
        }
        // НЕ удаляем input, просто очищаем значение, чтобы можно было выбрать тот же файл ещё раз
        input.value = '';
    });
    
    // Добавляем обработчик ошибок
    input.addEventListener('error', (e) => {
        console.error('Ошибка при работе с input:', e);
    });
    
    persistentFileInput = input;
    console.log('Input создан и добавлен в DOM:', {
        type: input.type,
        accept: input.accept,
        inDOM: document.body.contains(input) || (selectButton && selectButton.contains(input))
    });
    return input;
}

// Инициализация Telegram Web App
if (window.Telegram.WebApp.initData === '') {
    console.error('Telegram Web App не инициализирован правильно');
    document.body.innerHTML = '<div style="padding: 20px; color: red;">Ошибка: приложение должно быть открыто из Telegram</div>';
} else {
    console.log('Telegram Web App успешно инициализирован');
    console.log('InitData:', window.Telegram.WebApp.initData);
    tg.expand();
    tg.enableClosingConfirmation();
    
    // Обработчики событий Telegram Web App
    tg.onEvent('viewportChanged', () => {
        console.log('Viewport изменен');
        resetAppState(); // Сбрасываем состояние при изменении viewport
    });
    
    tg.onEvent('themeChanged', () => {
        console.log('Тема изменена');
        resetAppState(); // Сбрасываем состояние при изменении темы
    });
}

// Глобальный обработчик ошибок
window.addEventListener('error', (event) => {
    console.error('❌ Глобальная ошибка:', event.error);
    console.error('Сообщение:', event.message);
    console.error('Файл:', event.filename);
    console.error('Строка:', event.lineno);
    console.error('Колонка:', event.colno);
    console.error('Стек:', event.error?.stack);
});

window.addEventListener('unhandledrejection', (event) => {
    console.error('❌ Необработанное отклонение промиса:', event.reason);
    console.error('Стек:', event.reason?.stack);
});

// Инициализация при загрузке страницы
document.addEventListener('DOMContentLoaded', () => {
    console.log('DOM загружен, инициализируем элементы');
    
    // Принудительно очищаем кэш для корректной работы
    if ('serviceWorker' in navigator) {
        navigator.serviceWorker.getRegistrations().then(function(registrations) {
            for(let registration of registrations) {
                registration.unregister();
            }
        });
    }
    
    initializeElements();
    
    // Проверяем, что элементы найдены
    if (!selectButton) {
        console.error('⚠️ selectButton не найден после initializeElements()!');
        // Пробуем найти ещё раз через небольшую задержку
        setTimeout(() => {
            initializeElements();
            if (selectButton) {
                console.log('✅ selectButton найден после повторной инициализации');
    setupSelectVideoHandler();
    setupCropButtonHandler();
            } else {
                console.error('❌ selectButton всё ещё не найден');
            }
        }, 100);
    } else {
        setupSelectVideoHandler();
        setupCropButtonHandler();
    }
    
    // Принудительно сбрасываем состояние при каждом запуске
    resetAppState();
    
    console.log('Инициализация завершена');
});

// Дополнительная инициализация при полной загрузке страницы
window.addEventListener('load', () => {
    console.log('Страница полностью загружена');
    // НЕ сбрасываем состояние при каждом load, только инициализируем если нужно
});

// Сброс при выгрузке страницы (когда miniapp закрывается)
window.addEventListener('beforeunload', () => {
    console.log('Страница выгружается, сбрасываем состояние');
    resetAppState();
});

// Убираем автоматический сброс при blur/focus, так как это мешает выбору видео
// window.addEventListener('blur', ...) - убрано
// window.addEventListener('focus', ...) - убрано

// Обработка нажатий на кнопки
document.querySelectorAll('.button').forEach(button => {
    button.addEventListener('click', function() {
        this.classList.add('active');
    });
});

// Обработка выбора видео (добавляем после инициализации элементов)
function setupSelectVideoHandler() {
    if (!selectButton) {
        console.error('selectButton не найден');
        return;
    }
    
    console.log('Настраиваем обработчик для кнопки "Выбрать видео"');
    
    // Убеждаемся, что input создан заранее
    ensureFileInput();
    
    // Используем прямой клик на input вместо обработчика кнопки
    // В Telegram Web App это более надёжно
    const input = ensureFileInput();
    
    // Если input внутри кнопки, клик по кнопке должен попадать на input
    // Но на всякий случай добавляем обработчик и на кнопку
    selectButton.addEventListener('click', (e) => {
        console.log('Кнопка "Выбрать видео" нажата');
        console.log('Event target:', e.target);
        console.log('Event currentTarget:', e.currentTarget);
        
        // Если клик уже попал на input, не делаем ничего
        if (e.target === input || e.target === persistentFileInput) {
            console.log('Клик попал на input, пропускаем');
            return;
        }
        
        // На всякий случай скрываем любые оверлеи перед кликом
        hideProcessingStatus();
        hideCompletionAlert();

        // Используем постоянный input
        const fileInput = ensureFileInput();
        
        if (!fileInput) {
            console.error('Не удалось создать или найти input для выбора файла');
            if (typeof tg.showAlert === 'function') {
                try {
                    tg.showAlert('Ошибка: не удалось инициализировать выбор файла');
                } catch (e) {
                    console.error('Ошибка при вызове tg.showAlert:', e);
                    alert('Ошибка: не удалось инициализировать выбор файла');
                }
            } else {
                alert('Ошибка: не удалось инициализировать выбор файла');
            }
            return;
        }
        
        console.log('Input найден:', {
            exists: !!fileInput,
            inDOM: document.body.contains(fileInput) || (selectButton && selectButton.contains(fileInput)),
            type: fileInput.type,
            accept: fileInput.accept,
            parent: fileInput.parentElement?.tagName
        });
        
        // Сбрасываем значение, чтобы повторный выбор того же файла тоже срабатывал
        fileInput.value = '';
        
        // Пробуем несколько способов активации input
        console.log('Пробуем активировать input...');
        
        // Способ 1: прямой клик
        try {
            fileInput.click();
            console.log('✅ input.click() вызван успешно');
        } catch (error) {
            console.error('❌ Ошибка при вызове input.click():', error);
            
            // Способ 2: focus + программный клик
            try {
                fileInput.focus();
                const clickEvent = new MouseEvent('click', {
                    bubbles: true,
                    cancelable: true,
                    view: window,
                    detail: 1
                });
                fileInput.dispatchEvent(clickEvent);
                console.log('✅ Попытка через dispatchEvent');
            } catch (error2) {
                console.error('❌ Ошибка при dispatchEvent:', error2);
                
                // Способ 3: создаём новый input и кликаем по нему
                try {
                    const tempInput = document.createElement('input');
                    tempInput.type = 'file';
                    tempInput.accept = 'video/*';
                    tempInput.style.display = 'none';
                    document.body.appendChild(tempInput);
                    
                    tempInput.addEventListener('change', (e) => {
                        const file = e.target.files && e.target.files[0];
                        if (file) {
                            handleVideoSelect(file);
                        }
                        document.body.removeChild(tempInput);
                    });
                    
                    tempInput.click();
                    console.log('✅ Попытка через временный input');
                } catch (error3) {
                    console.error('❌ Все способы не сработали:', error3);
                    if (typeof tg.showAlert === 'function') {
                        try {
                            tg.showAlert('Не удалось открыть выбор файла. Попробуйте обновить страницу.');
                        } catch (e) {
                            console.error('Ошибка при вызове tg.showAlert:', e);
                            alert('Не удалось открыть выбор файла. Попробуйте обновить страницу.');
                        }
                    } else {
                        alert('Не удалось открыть выбор файла. Попробуйте обновить страницу.');
                    }
                }
            }
        }
    });
    
    // Также добавляем обработчик напрямую на input (на случай если клик попадает на него)
    if (input) {
        input.addEventListener('click', (e) => {
            console.log('Прямой клик на input');
            // Не предотвращаем стандартное поведение
        });
    }
    
    console.log('Обработчик для кнопки "Выбрать видео" установлен');
}

// Функция для показа статусного сообщения
function showStatusMessage(message, duration = 4000) {
    const statusMessage = document.getElementById('status-message');
    statusMessage.textContent = message;
    statusMessage.classList.add('show');
    
    setTimeout(() => {
        statusMessage.classList.remove('show');
    }, duration);
}

// Функции для управления статус-индикатором
function showProcessingStatus() {
    const processingStatus = document.getElementById('processing-status');
    if (processingStatus) {
        processingStatus.style.display = 'block';
        console.log('Статус-индикатор показан');
    } else {
        console.error('processing-status элемент не найден');
    }
}

function hideProcessingStatus() {
    const processingStatus = document.getElementById('processing-status');
    if (processingStatus) {
        processingStatus.style.display = 'none';
        console.log('Статус-индикатор скрыт');
    }
}

function updateStatusStep(stepId) {
    const step = document.getElementById(stepId);
    if (step) {
        step.classList.add('completed');
    }
}

function setUploadProgressText(text) {
    const el = document.getElementById('status-uploading');
    if (!el) return;
    const span = el.querySelector('.status-text');
    if (span) span.textContent = text;
}

function resetProcessingStatus() {
    const steps = ['status-uploading', 'status-uploaded', 'status-processing', 'status-creating', 'status-sent'];
    steps.forEach(stepId => {
        const step = document.getElementById(stepId);
        if (step) {
            step.classList.remove('completed');
        }
    });
}

// Функция для показа алерта завершения. message — опционально, подставляется в completion-alert-title.
function showCompletionAlert(message) {
    const alert = document.getElementById('completion-alert');
    if (!alert) {
        console.error('completion-alert элемент не найден');
        return;
    }
    const title = alert.querySelector('.completion-alert-title');
    if (title && message) title.textContent = message;
    alert.classList.add('show');
    console.log('Показан алерт завершения');
}

// Функция для скрытия алерта завершения
function hideCompletionAlert() {
    const alert = document.getElementById('completion-alert');
    if (alert) {
        alert.classList.remove('show');
        console.log('Скрыт алерт завершения');
    }
}

// Функция для полного сброса состояния приложения
function resetAppState() {
    console.log('Начинаем сброс состояния приложения');
    
    // Предотвращаем множественные сбросы если уже есть видео
    if (videoFile && appStateReset) {
        console.log('Пропускаем сброс - видео уже загружено');
        return;
    }
    
    // Сбрасываем состояние видео
    videoFile = null;
    currentX = 0;
    currentY = 0;
    currentScale = 1;
    minScaleGlobal = 1;
    
    // Проверяем существование элементов перед их использованием
    if (videoPreview) {
        videoPreview.src = '';
        videoPreview.classList.remove('video-preview');
        // Сбрасываем трансформацию видео
        updateVideoTransform();
    }
    
    if (cropScreen) {
        cropScreen.classList.remove('active');
    }
    
    if (selectScreen) {
        selectScreen.classList.add('active');
    }
    
    // Скрываем статус-индикатор
    hideProcessingStatus();
    // Скрываем финальный алерт (мог оставаться видимым и блокировать клики)
    hideCompletionAlert();
    
    // Сбрасываем флаг инициализации контролов
    controlsInitialized = false;
    
    // Сбрасываем состояние скроллинга
    isScrolling = false;
    isDragging = false;
    startDistance = 0;
    
    // Устанавливаем флаг сброса
    appStateReset = true;
    
    console.log('Состояние приложения сброшено');
}

// Обработка скроллинга для десктопа
let isScrolling = false;
let startScrollX = 0;
let startScrollY = 0;
let scrollLeft = 0;
let scrollTop = 0;

function initializeDesktopScroll() {
    videoContainerElem = document.querySelector('.video-container');
    if (!videoContainerElem) return;
    if (window.innerWidth >= 768) {
        videoContainerElem.addEventListener('mousedown', startScroll);
        window.addEventListener('mousemove', handleScroll);
        window.addEventListener('mouseup', stopScroll);
        window.addEventListener('mouseleave', stopScroll);
    }
}

function startScroll(e) {
    isScrolling = true;
    if (!videoContainerElem) return;
    startScrollX = e.pageX - videoContainerElem.offsetLeft;
    startScrollY = e.pageY - videoContainerElem.offsetTop;
    scrollLeft = videoContainerElem.scrollLeft;
    scrollTop = videoContainerElem.scrollTop;
}

function handleScroll(e) {
    if (!isScrolling) return;
    e.preventDefault();
    if (!videoContainerElem) return;
    const x = e.pageX - videoContainerElem.offsetLeft;
    const y = e.pageY - videoContainerElem.offsetTop;
    const walkX = (x - startScrollX) * 2;
    const walkY = (y - startScrollY) * 2;
    videoContainerElem.scrollLeft = scrollLeft - walkX;
    videoContainerElem.scrollTop = scrollTop - walkY;
}

function stopScroll() {
    isScrolling = false;
}

// Обработка выбранного видео
function handleVideoSelect(file) {
    if (file.size > 100 * 1024 * 1024) {
        const message = 'Файл слишком большой. Максимальный размер — 100 МБ';
        if (typeof tg.showAlert === 'function') {
            try {
                tg.showAlert(message);
            } catch (e) {
                console.error('Ошибка при вызове tg.showAlert:', e);
                alert(message);
            }
        } else {
            alert(message);
        }
        return;
    }

    videoFile = file;
    const videoUrl = URL.createObjectURL(file);
    videoPreview.src = videoUrl;
    videoPreview.classList.add('video-preview');
    
    // Сбрасываем флаг сброса при загрузке нового видео
    appStateReset = false;

    videoPreview.onloadedmetadata = () => {
        if (videoPreview.duration > 60) {
            const message = 'Видео должно быть не длиннее 60 секунд';
            if (typeof tg.showAlert === 'function') {
                try {
                    tg.showAlert(message);
                } catch (e) {
                    console.error('Ошибка при вызове tg.showAlert:', e);
                    alert(message);
                }
            } else {
                alert(message);
            }
            return;
        }

        // Адаптируем размер видео напрямую под его ориентацию
        const videoNaturalWidth = videoPreview.videoWidth;
        const videoNaturalHeight = videoPreview.videoHeight;
        const videoAspectRatio = videoNaturalWidth / videoNaturalHeight;
        
        // Убираем класс video-preview чтобы контейнер был невидимым
        videoPreview.classList.remove('video-preview');
        
        // Устанавливаем размеры видео напрямую - делаем крупнее
        if (videoAspectRatio > 1) {
            // Горизонтальное видео - делаем шире и выше
            videoPreview.style.maxWidth = '95vw';
            videoPreview.style.maxHeight = '70vh';
        } else {
            // Вертикальное видео - делаем шире и выше
            videoPreview.style.maxWidth = '90vw';
            videoPreview.style.maxHeight = '85vh';
        }

        selectScreen.classList.remove('active');
        cropScreen.classList.add('active');

        // timeSlider.max = videoPreview.duration; // Закомментировано - убираем плеер
        // timeSlider.value = 0;
        
        // Автоматически воспроизводим видео
        videoPreview.play();
        // playPauseButton.querySelector('.play-icon').textContent = '⏸'; // Закомментировано - убираем плеер

        // Сбрасываем состояние
        currentX = 0;
        currentY = 0;
        currentScale = 1;
        updateVideoTransform();

        // Устанавливаем начальный размер кроп-фрейма адаптивно
        // Делаем его больше (70% от меньшей стороны видео на экране) для более широкого обзора
        const videoRectForCrop = videoPreview.getBoundingClientRect();
        const minVideoDimension = Math.min(videoRectForCrop.width, videoRectForCrop.height);
        const cropSize = Math.min(350, minVideoDimension * 0.7); // 70% от меньшей стороны, но не больше 350px
        cropFrame.style.width = `${cropSize}px`;
        cropFrame.style.height = `${cropSize}px`;
        
        // Получаем реальные размеры видео и размеры на экране
        const videoRect = videoPreview.getBoundingClientRect();
        const cropRect = cropFrame.getBoundingClientRect();
        const naturalWidth = videoPreview.videoWidth;
        const naturalHeight = videoPreview.videoHeight;
        
        // Вычисляем минимальный масштаб так, чтобы круг помещался внутри видео
        // Учитываем реальные пропорции видео, а не только размеры на экране
        const aspectRatio = naturalWidth / naturalHeight;
        const screenAspectRatio = videoRect.width / videoRect.height;
        
        // Для горизонтального видео (ширина > высоты) минимальный масштаб должен быть больше
        if (aspectRatio > 1) {
            // Горизонтальное видео: минимальный масштаб ограничен высотой экрана
            // Но учитываем, что видео может быть меньше по высоте чем контейнер
            minScaleGlobal = Math.max(
                cropRect.height / videoRect.height,
                cropRect.width / (videoRect.width * 0.8) // Дополнительный запас для горизонтального
            );
        } else {
            // Вертикальное видео: минимальный масштаб ограничен шириной экрана  
            minScaleGlobal = cropRect.width / videoRect.width;
        }
        
        // Увеличиваем диапазон зума для горизонтального видео
        const maxScaleHorizontal = aspectRatio > 1 ? 4.0 : 2.5;
        // Устанавливаем начальный масштаб больше минимального, чтобы видео было крупнее
        // Это даст более крупное отображение видео в мини-аппе
        currentScale = minScaleGlobal * 1.5; // Увеличиваем на 50% для более крупного видео
        
        // Не применяем никаких смещений - позволяем CSS object-fit: contain самому центрировать
        currentX = 0;
        currentY = 0;

        updateVideoTransform();
        
        // Принудительно центрируем видео после загрузки
        setTimeout(() => {
            centerVideoAfterLoad();
        }, 100);
        
        initializeMovementControls(); // Инициализируем только обработчики движения
        initializeDesktopScroll();
    };
}

// Флаги для предотвращения дублирования обработчиков
let controlsInitialized = false;
let appStateReset = false; // Флаг для предотвращения множественных сбросов

// Инициализация контролов видео - ЗАКОММЕНТИРОВАНО (убираем плеер)
/*
function initializeVideoControls() {
    if (controlsInitialized) return; // Предотвращаем дублирование обработчиков
    
    const videoWrapper = document.querySelector('.video-wrapper');

    // Воспроизведение/пауза
    playPauseButton.addEventListener('click', () => {
        if (videoPreview.paused) {
            videoPreview.play();
            playPauseButton.querySelector('.play-icon').textContent = '⏸';
        } else {
            videoPreview.pause();
            playPauseButton.querySelector('.play-icon').textContent = '▶';
        }
    });

    // Обновление слайдера времени
    videoPreview.addEventListener('timeupdate', () => {
        timeSlider.value = videoPreview.currentTime;
    });

    // Перемотка видео
    timeSlider.addEventListener('input', () => {
        videoPreview.currentTime = timeSlider.value;
    });

    // Зацикливание видео
    videoPreview.addEventListener('ended', () => {
        videoPreview.currentTime = 0;
        videoPreview.play();
    });

    // Обработчики для перемещения
    videoWrapper.addEventListener('touchstart', handleTouchStart, { passive: false });
    videoWrapper.addEventListener('touchmove', handleTouchMove, { passive: false });
    videoWrapper.addEventListener('touchend', handleTouchEnd);

    // Обработчики для масштабирования
    videoWrapper.addEventListener('touchstart', handlePinchStart, { passive: false });
    videoWrapper.addEventListener('touchmove', handlePinchMove, { passive: false });
    videoWrapper.addEventListener('touchend', handlePinchEnd);
    
    controlsInitialized = true;
}
*/

// Инициализация только обработчиков движения (без плеера)
function initializeMovementControls() {
    if (controlsInitialized) return; // Предотвращаем дублирование обработчиков
    
    const videoWrapper = document.querySelector('.video-wrapper');

    // Обработчики для перемещения
    videoWrapper.addEventListener('touchstart', handleTouchStart, { passive: false });
    videoWrapper.addEventListener('touchmove', handleTouchMove, { passive: false });
    videoWrapper.addEventListener('touchend', handleTouchEnd);

    // Обработчики для масштабирования
    videoWrapper.addEventListener('touchstart', handlePinchStart, { passive: false });
    videoWrapper.addEventListener('touchmove', handlePinchMove, { passive: false });
    videoWrapper.addEventListener('touchend', handlePinchEnd);
    
    controlsInitialized = true;
}

function handleTouchStart(e) {
    if (e.touches.length === 1) {
        isDragging = true;
        const touch = e.touches[0];
        startX = touch.clientX - currentX;
        startY = touch.clientY - currentY;
        e.preventDefault();
    }
}

function handleTouchMove(e) {
    if (isDragging && e.touches.length === 1) {
        const touch = e.touches[0];
        // Вычисляем смещение от начальной точки касания
        const deltaX = touch.clientX - (startX + currentX);
        const deltaY = touch.clientY - (startY + currentY);
        
        // Добавляем коэффициент замедления для более плавного и контролируемого перемещения
        const sensitivity = 0.8; // Коэффициент чувствительности (меньше = медленнее)
        const adjustedDeltaX = deltaX * sensitivity;
        const adjustedDeltaY = deltaY * sensitivity;
        
        // Кандидатное новое смещение
        let newX = currentX + adjustedDeltaX;
        let newY = currentY + adjustedDeltaY;
        
        // Жестко ограничиваем движение - оверлей не может выйти за пределы видео
        const { minDx, maxDx, minDy, maxDy } = computeDeltaBoundsForScale(currentScale, currentScale);
        const dx = newX - currentX;
        const dy = newY - currentY;
        
        // Ограничиваем смещение жесткими границами
        const clampedDx = Math.max(minDx, Math.min(maxDx, dx));
        const clampedDy = Math.max(minDy, Math.min(maxDy, dy));
        
        currentX = currentX + clampedDx;
        currentY = currentY + clampedDy;
        
        // Обновляем начальные координаты для следующего движения
        startX = touch.clientX - currentX;
        startY = touch.clientY - currentY;
        
        updateVideoTransform();
        e.preventDefault();
    }
}

function handleTouchEnd() {
    isDragging = false;
    // Жесткие границы уже работают в handleTouchMove, дополнительный возврат не нужен
}

function handlePinchStart(e) {
    if (e.touches.length === 2) {
        const touch1 = e.touches[0];
        const touch2 = e.touches[1];
        startDistance = Math.hypot(
            touch1.clientX - touch2.clientX,
            touch1.clientY - touch2.clientY
        );
        pinchStartScale = currentScale;
        // Сохраняем текущее смещение для формулы зума
        pinchStartX = currentX;
        pinchStartY = currentY;
        e.preventDefault();
    }
}

function handlePinchMove(e) {
    if (e.touches.length === 2) {
        const touch1 = e.touches[0];
        const touch2 = e.touches[1];
        const currentDistance = Math.hypot(
            touch1.clientX - touch2.clientX,
            touch1.clientY - touch2.clientY
        );
        
        if (startDistance > 0) {
            const scaleFactor = currentDistance / startDistance;
            const targetScale = pinchStartScale * scaleFactor;
            const clampedScale = Math.min(Math.max(targetScale, minScaleGlobal), MAX_SCALE);

            // Центр между пальцами в координатах экрана
            const anchorScreenX = (touch1.clientX + touch2.clientX) / 2;
            const anchorScreenY = (touch1.clientY + touch2.clientY) / 2;
            
            // Получаем текущие размеры и позицию видео
            const videoRect = videoPreview.getBoundingClientRect();
            
            // Якорь в координатах экрана относительно центра видео
            const videoCenterX = videoRect.left + videoRect.width / 2;
            const videoCenterY = videoRect.top + videoRect.height / 2;
            const anchorX = anchorScreenX - videoCenterX;
            const anchorY = anchorScreenY - videoCenterY;
            
            const ratio = clampedScale / pinchStartScale;

            // Простая и правильная формула: новый центр = старый центр + (1 - ratio) * якорь
            const rawNewX = pinchStartX + (1 - ratio) * anchorX;
            const rawNewY = pinchStartY + (1 - ratio) * anchorY;

            // Жестко ограничиваем движение при зуме - оверлей не может выйти за пределы видео
            const { minDx, maxDx, minDy, maxDy } = computeDeltaBoundsForScale(clampedScale, pinchStartScale);
            const dx = rawNewX - currentX;
            const dy = rawNewY - currentY;
            
            const clampedDx = Math.max(minDx, Math.min(maxDx, dx));
            const clampedDy = Math.max(minDy, Math.min(maxDy, dy));
            
            currentX = currentX + clampedDx;
            currentY = currentY + clampedDy;
            currentScale = clampedScale;
            updateVideoTransform();
        }
        e.preventDefault();
    }
}

function handlePinchEnd() {
    startDistance = 0;
    // Жесткие границы уже работают в handlePinchMove, дополнительный возврат не нужен
}

function updateVideoTransform() {
    videoPreview.style.transform = `translate(${currentX}px, ${currentY}px) scale(${currentScale})`;
}

// Функция для проверки центрирования видео после загрузки
function centerVideoAfterLoad() {
    if (!videoPreview || !videoFile) return;
    
    const videoRect = videoPreview.getBoundingClientRect();
    const naturalWidth = videoPreview.videoWidth;
    const naturalHeight = videoPreview.videoHeight;
    const aspectRatio = naturalWidth / naturalHeight;
    
    // Убеждаемся что видео центрировано CSS object-fit: contain
    // Сбрасываем все смещения и масштаб к начальным значениям
    currentX = 0;
    currentY = 0;
    // Масштаб уже установлен выше, не меняем его здесь
    
    // Принудительно центрируем видео через CSS
    videoPreview.style.margin = 'auto';
    videoPreview.style.display = 'block';
    
    console.log('Видео проверено на центрирование:', {
        aspectRatio: aspectRatio,
        videoRect: {
            width: videoRect.width,
            height: videoRect.height
        },
        naturalSize: {
            width: naturalWidth,
            height: naturalHeight
        },
        currentScale: currentScale
    });
    
    updateVideoTransform();
}

// --------- Упругие границы и авто-возврат ---------
function clamp(value, min, max) {
    return Math.max(min, Math.min(max, value));
}

function rubber(value, min, max, elasticity = ELASTICITY) {
    if (value < min) return min - (min - value) * elasticity;
    if (value > max) return max + (value - max) * elasticity;
    return value;
}

function getCurrentRects() {
    const vRect = videoPreview.getBoundingClientRect();
    const cRect = cropFrame.getBoundingClientRect();
    return { vRect, cRect };
}

// Возвращает реальный прямоугольник отображаемого видео внутри элемента
// с учётом object-fit: contain и текущего transform (scale/translate)
function getDisplayedVideoRect() {
    const vRect = videoPreview.getBoundingClientRect();
    const naturalWidth = videoPreview.videoWidth;
    const naturalHeight = videoPreview.videoHeight;
    if (!naturalWidth || !naturalHeight) {
        return {
            left: vRect.left,
            top: vRect.top,
            width: vRect.width,
            height: vRect.height,
            centerX: vRect.left + vRect.width / 2,
            centerY: vRect.top + vRect.height / 2
        };
    }
    const elementRatio = vRect.width / vRect.height;
    const videoRatio = naturalWidth / naturalHeight;

    let displayWidth, displayHeight, left, top;
    if (elementRatio > videoRatio) {
        // ограничено высотой, по бокам есть «пустые» поля
        displayHeight = vRect.height;
        displayWidth = displayHeight * videoRatio;
        left = vRect.left + (vRect.width - displayWidth) / 2;
        top = vRect.top;
    } else {
        // ограничено шириной, сверху/снизу есть поля
        displayWidth = vRect.width;
        displayHeight = displayWidth / videoRatio;
        left = vRect.left;
        top = vRect.top + (vRect.height - displayHeight) / 2;
    }

    return {
        left,
        top,
        width: displayWidth,
        height: displayHeight,
        centerX: left + displayWidth / 2,
        centerY: top + displayHeight / 2
    };
}

// Вычисляет допустимый диапазон дельт (dx, dy) для смещения,
// чтобы круг оставался внутри видео при целевом масштабе
function computeDeltaBoundsForScale(targetScale, scaleFrom = currentScale) {
    const { vRect, cRect } = getCurrentRects();
    const displayed = getDisplayedVideoRect();
    const halfCropW = cRect.width / 2;
    const halfCropH = cRect.height / 2;

    // Размеры видео после масштабирования targetScale
    const ratio = targetScale / scaleFrom;
    const halfVideoWNew = (displayed.width * ratio) / 2;
    const halfVideoHNew = (displayed.height * ratio) / 2;
    
    // Центр оверлея на экране (фиксирован)
    const overlayCenterX = cRect.left + cRect.width / 2;
    const overlayCenterY = cRect.top + cRect.height / 2;
    
    // Центр видео на экране БЕЗ учета transform
    const videoCenterXBase = displayed.centerX;
    const videoCenterYBase = displayed.centerY;

    // С учетом transform, весь элемент videoPreview смещается на (currentX, currentY)
    // Поэтому центр отображаемого видео тоже смещается на (currentX, currentY)
    const videoCenterXNow = videoCenterXBase + currentX;
    const videoCenterYNow = videoCenterYBase + currentY;
    
    // Вычисляем границы: оверлей должен оставаться полностью внутри видео
    // Центр оверлея должен быть в пределах: [videoCenter - (halfVideo - halfCrop), videoCenter + (halfVideo - halfCrop)]
    const allowedHorizontalMovement = Math.max(0, halfVideoWNew - halfCropW);
    const allowedVerticalMovement = Math.max(0, halfVideoHNew - halfCropH);
    
    // После изменения currentX на dx, новый центр видео будет videoCenterXNow + dx
    // Этот центр должен быть в пределах: [overlayCenterX - allowedHorizontalMovement, overlayCenterX + allowedHorizontalMovement]
    const minDx = (overlayCenterX - allowedHorizontalMovement) - videoCenterXNow;
    const maxDx = (overlayCenterX + allowedHorizontalMovement) - videoCenterXNow;
    const minDy = (overlayCenterY - allowedVerticalMovement) - videoCenterYNow;
    const maxDy = (overlayCenterY + allowedVerticalMovement) - videoCenterYNow;
    
    return { minDx, maxDx, minDy, maxDy };
}

function applyElasticBounds(newX, newY, targetScale, options = {}) {
    const { useScaleChange } = options;
    const fromScale = useScaleChange ? useScaleChange.from : currentScale;
    const { minDx, maxDx, minDy, maxDy } = computeDeltaBoundsForScale(targetScale, fromScale);

    // Смещение от текущей позиции
    const dx = newX - currentX;
    const dy = newY - currentY;

    // Упругая коррекция - ограничиваем смещение
    const clampedDx = Math.max(minDx, Math.min(maxDx, dx));
    const clampedDy = Math.max(minDy, Math.min(maxDy, dy));

    return { x: currentX + clampedDx, y: currentY + clampedDy };
}

function snapToBounds() {
    // Получаем текущие границы
    const { minDx, maxDx, minDy, maxDy } = computeDeltaBoundsForScale(currentScale, currentScale);
    
    // Вычисляем целевую позицию - смещение должно быть в пределах границ
    const targetDx = Math.max(minDx, Math.min(maxDx, 0));
    const targetDy = Math.max(minDy, Math.min(maxDy, 0));
    
    // Новые координаты
    const targetX = currentX + targetDx;
    const targetY = currentY + targetDy;

    // Если уже внутри границ, ничего не делаем
    if (Math.abs(targetX - currentX) < 1 && Math.abs(targetY - currentY) < 1) return;

    // Плавная анимация к целевой позиции
    const prevTransition = videoPreview.style.transition;
    videoPreview.style.transition = 'transform 150ms cubic-bezier(0.25, 0.46, 0.45, 0.94)';
    currentX = targetX;
    currentY = targetY;
    updateVideoTransform();
    
    setTimeout(() => {
        videoPreview.style.transition = prevTransition || '';
    }, 200);
}

// Обработка кнопки "Обрезать" (добавляем после инициализации элементов)
function setupCropButtonHandler() {
    if (!cropButton) {
        console.error('cropButton не найден');
        return;
    }
    
cropButton.addEventListener('click', async () => {
        console.log('🔵 Кнопка "Обрезать" нажата');
        console.log('🔵 videoFile:', videoFile ? `есть (${videoFile.name}, ${videoFile.size} байт)` : 'НЕТ');
        console.log('🔵 currentScale:', currentScale);
        console.log('🔵 cropFrame:', cropFrame ? 'найден' : 'НЕ НАЙДЕН');
        console.log('🔵 videoPreview:', videoPreview ? 'найден' : 'НЕ НАЙДЕН');
        
    if (!videoFile) {
            console.log('Видео не выбрано');
        const message = 'Пожалуйста, выберите видео';
        if (typeof tg.showAlert === 'function') {
            try {
                tg.showAlert(message);
            } catch (e) {
                console.error('Ошибка при вызове tg.showAlert:', e);
                alert(message);
            }
        } else {
            alert(message);
        }
        return;
    }

        // Проверка размера до начала загрузки — алерт сразу, без ожидания
        if (videoFile.size > 100 * 1024 * 1024) {
            const msg = 'Файл слишком большой (макс. 100 МБ).';
            if (typeof tg !== 'undefined' && typeof tg.showAlert === 'function') {
                try { tg.showAlert(msg); } catch (e) { alert(msg); }
            } else {
                alert(msg);
            }
            return;
        }

        console.log('🟢 Начинаем обработку видео');
        
        try {
            console.log('🟢 Шаг 1: Меняем кнопку');
            // Меняем кнопку на "Ожидайте" и делаем её неактивной
            cropButton.textContent = 'Ожидайте';
            cropButton.style.background = '#666';
            cropButton.disabled = true;
            
            console.log('🟢 Шаг 2: Показываем статус-индикатор');
            // Показываем статус-индикатор
            resetProcessingStatus();
            showProcessingStatus();
            
            console.log('🟢 Шаг 3: Обновляем статус на uploading');
            updateStatusStep('status-uploading');
            
            console.log('🟢 Шаг 4: Получаем элементы видео');

        const video = document.getElementById('video-preview');
            if (!video) {
                throw new Error('Элемент video-preview не найден');
            }
            console.log('🟢 video элемент найден, videoWidth:', video.videoWidth, 'videoHeight:', video.videoHeight);
            
        const videoRect = video.getBoundingClientRect();
        const cropRect = cropFrame.getBoundingClientRect();
            console.log('🟢 videoRect:', videoRect.width, 'x', videoRect.height);
            console.log('🟢 cropRect:', cropRect.width, 'x', cropRect.height);
        
        // Получаем реальные размеры видео без учета масштаба
        const videoElement = videoPreview;
        const naturalWidth = videoElement.videoWidth;
        const naturalHeight = videoElement.videoHeight;
        
            // Получаем реальные размеры отображаемого видео БЕЗ учета transform
            const displayedBase = getDisplayedVideoRect();
            
            // С transform-origin: center center, transform применяется от центра элемента videoPreview
            // Центр элемента videoPreview на экране (это точка отсчета для transform)
            const elementCenterX = videoRect.left + videoRect.width / 2;
            const elementCenterY = videoRect.top + videoRect.height / 2;
        
            // Центр отображаемого видео БЕЗ transform (из getDisplayedVideoRect)
            const displayedBaseCenterX = displayedBase.centerX;
            const displayedBaseCenterY = displayedBase.centerY;
            
            // Смещение центра отображаемого видео относительно центра элемента (БЕЗ transform)
            const baseOffsetX = displayedBaseCenterX - elementCenterX;
            const baseOffsetY = displayedBaseCenterY - elementCenterY;
            
            // С учетом transform translate(currentX, currentY) scale(currentScale):
            // 1. Сначала масштабируем смещение на currentScale
            // 2. Затем добавляем currentX/currentY
            // 3. И добавляем к центру элемента
            const displayedCenterX = elementCenterX + (baseOffsetX * currentScale) + currentX;
            const displayedCenterY = elementCenterY + (baseOffsetY * currentScale) + currentY;
            
            // Размеры отображаемого видео с учетом масштаба
            const displayedWidthScaled = displayedBase.width * currentScale;
            const displayedHeightScaled = displayedBase.height * currentScale;
        
        // Центр области кропа на экране
        const cropCenterX = cropRect.left + cropRect.width / 2;
        const cropCenterY = cropRect.top + cropRect.height / 2;
        
            // Смещение центра кропа относительно центра отображаемого видео (в экранных пикселях)
            const screenOffsetX = cropCenterX - displayedCenterX;
            const screenOffsetY = cropCenterY - displayedCenterY;
        
        // Переводим экранные координаты в координаты исходного видео
            // Коэффициент масштабирования: насколько пиксель на экране соответствует пикселю в исходном видео
            const scaleFactorX = naturalWidth / displayedWidthScaled;
            const scaleFactorY = naturalHeight / displayedHeightScaled;
            
            // Смещение центра кропа в координатах исходного видео (относительно центра видео)
            const videoOffsetX = screenOffsetX * scaleFactorX;
            const videoOffsetY = screenOffsetY * scaleFactorY;
        
            // Центр кропа в координатах исходного видео (абсолютные координаты)
            const cropCenterInVideoX = (naturalWidth / 2) + videoOffsetX;
            const cropCenterInVideoY = (naturalHeight / 2) + videoOffsetY;
        
            // Проверяем, что размеры видео валидны
            if (!naturalWidth || !naturalHeight || naturalWidth === 0 || naturalHeight === 0) {
                throw new Error(`Неверные размеры видео: ${naturalWidth}x${naturalHeight}`);
            }
        
        // Размер области кропа в координатах исходного видео
            // Кроп-фрейм квадратный, поэтому используем его ширину
            // Коэффициент масштабирования должен быть одинаковым для X и Y (квадратный кроп)
            // Используем средний коэффициент для более точного расчета
            const scaleFactor = (scaleFactorX + scaleFactorY) / 2;
            const cropSizeInVideo = cropRect.width * scaleFactor;
        
            // Ограничиваем размер кропа максимальным размером (меньшая сторона видео)
            const maxCropSize = Math.min(naturalWidth, naturalHeight);
            const finalCropSize = Math.min(cropSizeInVideo, maxCropSize);
            
            // Переводим в нормализованные координаты (0-1)
            // x, y - это центр области кропа в долях от [0,1]
            const x = Math.max(0, Math.min(1, cropCenterInVideoX / naturalWidth));
            const y = Math.max(0, Math.min(1, cropCenterInVideoY / naturalHeight));
            
            // width, height - это размер области кропа в долях от [0,1]
            // Для квадратного кропа width и height должны быть одинаковыми
            const normalizedSize = finalCropSize / Math.min(naturalWidth, naturalHeight);
            const width = Math.min(1, normalizedSize);
            const height = Math.min(1, normalizedSize);

            // Проверяем, что все значения валидны
            const cropDataObj = {
                x: Number(x) || 0.5,
                y: Number(y) || 0.5,
                width: Number(width) || 0.5,
                height: Number(height) || 0.5,
                scale: Number(currentScale) || 1
            };
            
            // Отправляем детальные логи на сервер для отладки
            const logDetails = {
                displayedBase: {
                    width: displayedBase.width,
                    height: displayedBase.height,
                    centerX: displayedBase.centerX,
                    centerY: displayedBase.centerY
                },
                elementRect: {
                    left: videoRect.left,
                    top: videoRect.top,
                    width: videoRect.width,
                    height: videoRect.height,
                    centerX: elementCenterX,
                    centerY: elementCenterY
                },
                transform: {
                    currentX: currentX,
                    currentY: currentY,
                    currentScale: currentScale
                },
                displayedScaled: {
                    width: displayedWidthScaled,
                    height: displayedHeightScaled,
                    centerX: displayedCenterX,
                    centerY: displayedCenterY
                },
                cropRect: {
                    left: cropRect.left,
                    top: cropRect.top,
                    width: cropRect.width,
                    height: cropRect.height,
                    centerX: cropCenterX,
                    centerY: cropCenterY
                },
                screenOffset: {
                    x: screenOffsetX,
                    y: screenOffsetY
                },
                scaleFactors: {
                    x: scaleFactorX,
                    y: scaleFactorY
                },
                videoOffset: {
                    x: videoOffsetX,
                    y: videoOffsetY
                },
                cropCenterInVideo: {
                    x: cropCenterInVideoX,
                    y: cropCenterInVideoY
                },
                cropSizeInVideo: cropSizeInVideo,
                naturalSize: {
                    width: naturalWidth,
                    height: naturalHeight
                },
                normalized: {
            x: x,
            y: y,
            width: width,
                    height: height
                },
                finalCropData: cropDataObj
            };
            
            console.log('🔍 ДЕТАЛИ ВЫЧИСЛЕНИЯ КРОПА:', JSON.stringify(logDetails, null, 2));
            console.log('CropData объект перед отправкой:', cropDataObj);
            console.log('Проверка значений:', {
                x: typeof x, y: typeof y, width: typeof width, height: typeof height, scale: typeof currentScale,
                xVal: x, yVal: y, widthVal: width, heightVal: height, scaleVal: currentScale
            });

            const formData = new FormData();
            formData.append('video', videoFile);
            formData.append('cropData', JSON.stringify(cropDataObj));

        const initData = window.Telegram.WebApp.initDataUnsafe;
        if (!initData.user?.id) {
            throw new Error('Не удалось получить идентификатор чата');
        }
        formData.append('chatId', initData.user.id.toString());

            // Проверяем, что все необходимые данные есть
            if (!videoFile) {
                throw new Error('Видео файл не найден');
            }
            if (!initData?.user?.id) {
                throw new Error('Не удалось получить идентификатор пользователя');
            }

        if (typeof tg.showProgress === 'function') {
            tg.showProgress();
        }

        setUploadProgressText('Загрузка 0%');
        console.log('Отправляем запрос на сервер (XHR с прогрессом)...');

        const responseText = await new Promise((resolve, reject) => {
            const xhr = new XMLHttpRequest();
            const url = '/rounds/api/upload';
            xhr.open('POST', url);

            xhr.upload.onprogress = (e) => {
                if (e.lengthComputable && e.total > 0) {
                    const pct = Math.round((e.loaded / e.total) * 100);
                    setUploadProgressText('Загрузка ' + pct + '%');
                } else {
                    setUploadProgressText('Загрузка…');
                }
            };

            xhr.onload = () => {
                if (xhr.status >= 200 && xhr.status < 300) {
                    resolve(xhr.responseText);
                } else {
                    let msg = xhr.responseText || 'Ошибка ' + xhr.status;
                    try {
                        const j = JSON.parse(xhr.responseText || '{}');
                        if (j && typeof j.error === 'string') msg = j.error;
                    } catch (_) {}
                    reject(new Error(msg));
                }
            };
            xhr.onerror = () => reject(new Error('Ошибка сети при загрузке'));
            xhr.send(formData);
        });

        updateStatusStep('status-uploaded');
        updateStatusStep('status-processing');
        console.log('Загрузка завершена, ответ получен:', responseText);

        // Поочерёдно отмечаем «Создание кружка» и «Кружок в чате», затем показываем финальный алерт
        await new Promise(r => setTimeout(r, 400));
        updateStatusStep('status-creating');
        await new Promise(r => setTimeout(r, 400));
        updateStatusStep('status-sent');

        hideProcessingStatus();
        if (cropButton) {
            cropButton.textContent = 'Обрезать';
            cropButton.style.background = 'var(--primary-color)';
            cropButton.disabled = false;
        }
        showCompletionAlert('Кружок создаётся, придёт в чат. Можете закрыть мини-апп.');
        setTimeout(() => {
            hideCompletionAlert();
            resetAppState();
            if (typeof tg !== 'undefined' && typeof tg.close === 'function') tg.close();
        }, 2500);

    } catch (error) {
            console.error('❌ Ошибка при обработке видео:', error);
            console.error('Тип ошибки:', error?.constructor?.name);
            console.error('Стек ошибки:', error?.stack);
            console.error('Детали ошибки:', {
                message: error?.message,
                name: error?.name,
                toString: error?.toString(),
                cause: error?.cause
            });
            
            if (error?.message && (error.message.includes('fetch') || error.message.includes('Failed to fetch') || error.message.includes('Ошибка сети'))) {
                console.error('⚠️ Сетевая ошибка при загрузке');
            }
            
        hideProcessingStatus();
        
        // Возвращаем кнопку в исходное состояние
        cropButton.textContent = 'Обрезать';
        cropButton.style.background = 'var(--primary-color)';
        cropButton.disabled = false;
        
        // Сбрасываем состояние при ошибке
        resetAppState();
            
            // Извлекаем сообщение об ошибке
            let errorMessage = 'Произошла ошибка при обработке видео';
            if (error?.message) {
                errorMessage = error.message;
            } else if (error?.toString && typeof error.toString === 'function') {
                errorMessage = error.toString();
            } else if (typeof error === 'string') {
                errorMessage = error;
            }
            
            // Обрезаем сообщение до 200 символов (лимит Telegram Web App)
            const shortMessage = errorMessage.length > 200 ? errorMessage.substring(0, 197) + '...' : errorMessage;
            
            console.log('Показываем ошибку пользователю:', shortMessage);
            
        if (typeof tg.showAlert === 'function') {
                try {
                    tg.showAlert(shortMessage);
                } catch (e) {
                    console.error('Ошибка при вызове tg.showAlert:', e);
                    alert(shortMessage);
                }
        } else {
                alert(shortMessage);
        }
    } finally {
        if (typeof tg.hideProgress === 'function') {
            tg.hideProgress();
        }
    }
}); 
} 
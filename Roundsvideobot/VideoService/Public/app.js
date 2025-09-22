let tg = window.Telegram.WebApp;

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
    setupSelectVideoHandler();
    setupCropButtonHandler();
    
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
    
    selectButton.addEventListener('click', (e) => {
        e.preventDefault();
        e.stopPropagation();
        
        console.log('Кнопка "Выбрать видео" нажата');
        
        // НЕ сбрасываем состояние при выборе видео, чтобы не мешать загрузке
        
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = 'video/*';
    input.style.display = 'none';
    document.body.appendChild(input);

    input.addEventListener('change', (e) => {
        const file = e.target.files[0];
        if (file) {
                console.log('Файл выбран:', file.name);
            handleVideoSelect(file);
        }
        document.body.removeChild(input);
    });

    input.click();
});
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

function resetProcessingStatus() {
    const steps = ['status-uploading', 'status-uploaded', 'status-processing', 'status-creating', 'status-sent'];
    steps.forEach(stepId => {
        const step = document.getElementById(stepId);
        if (step) {
            step.classList.remove('completed');
        }
    });
}

// Функция для показа алерта завершения
function showCompletionAlert() {
    const alert = document.getElementById('completion-alert');
    if (alert) {
        alert.classList.add('show');
        console.log('Показан алерт завершения');
    } else {
        console.error('completion-alert элемент не найден');
    }
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
        if (typeof tg.showAlert === 'function') {
            tg.showAlert('Файл слишком большой. Максимальный размер - 100 МБ');
        } else {
            alert('Файл слишком большой. Максимальный размер - 100 МБ');
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
            if (typeof tg.showAlert === 'function') {
                tg.showAlert('Видео должно быть не длиннее 60 секунд');
            } else {
                alert('Видео должно быть не длиннее 60 секунд');
            }
            return;
        }

        // Адаптируем размер видео напрямую под его ориентацию
        const videoNaturalWidth = videoPreview.videoWidth;
        const videoNaturalHeight = videoPreview.videoHeight;
        const videoAspectRatio = videoNaturalWidth / videoNaturalHeight;
        
        // Убираем класс video-preview чтобы контейнер был невидимым
        videoPreview.classList.remove('video-preview');
        
        // Устанавливаем размеры видео напрямую
        if (videoAspectRatio > 1) {
            // Горизонтальное видео - делаем шире
            videoPreview.style.maxWidth = '80vw';
            videoPreview.style.maxHeight = '50vh';
        } else {
            // Вертикальное видео - делаем уже
            videoPreview.style.maxWidth = '60vw';
            videoPreview.style.maxHeight = '70vh';
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

        // Устанавливаем начальный размер кроп-фрейма (уменьшен на 16% от оригинала)
        cropFrame.style.width = '252px';
        cropFrame.style.height = '252px';
        
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
        currentScale = Math.max(minScaleGlobal, minScaleGlobal * 1.05);
        
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
        // Кандидатное новое смещение
        let newX = touch.clientX - startX;
        let newY = touch.clientY - startY;
        
        // Жестко ограничиваем движение - оверлей не может выйти за пределы видео
        const { minDx, maxDx, minDy, maxDy } = computeDeltaBoundsForScale(currentScale, currentScale);
        const dx = newX - currentX;
        const dy = newY - currentY;
        
        // Ограничиваем смещение жесткими границами
        const clampedDx = Math.max(minDx, Math.min(maxDx, dx));
        const clampedDy = Math.max(minDy, Math.min(maxDy, dy));
        
        currentX = currentX + clampedDx;
        currentY = currentY + clampedDy;
        
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
    // Не применяем никаких смещений - оставляем CSS делать свою работу
    currentX = 0;
    currentY = 0;
    
    console.log('Видео проверено на центрирование:', {
        aspectRatio: aspectRatio,
        videoRect: {
            width: videoRect.width,
            height: videoRect.height
        },
        naturalSize: {
            width: naturalWidth,
            height: naturalHeight
        }
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

// Вычисляет допустимый диапазон дельт (dx, dy) для смещения,
// чтобы круг оставался внутри видео при целевом масштабе
function computeDeltaBoundsForScale(targetScale, scaleFrom = currentScale) {
    const { vRect, cRect } = getCurrentRects();
    const overlayCenterX = cRect.left + cRect.width / 2;
    const overlayCenterY = cRect.top + cRect.height / 2;
    const halfCropW = cRect.width / 2;
    const halfCropH = cRect.height / 2;

    // Получаем реальные пропорции видео
    const naturalWidth = videoPreview.videoWidth;
    const naturalHeight = videoPreview.videoHeight;
    const aspectRatio = naturalWidth / naturalHeight;

    // Размеры видео после масштабирования targetScale
    const ratio = targetScale / scaleFrom;
    const halfVideoWNew = (vRect.width * ratio) / 2;
    const halfVideoHNew = (vRect.height * ratio) / 2;
    const videoCenterXNow = vRect.left + vRect.width / 2;
    const videoCenterYNow = vRect.top + vRect.height / 2;

    // Вычисляем границы для всех типов видео
    let minCenterX, maxCenterX, minCenterY, maxCenterY;
    
    // Горизонтальное движение: оверлей должен оставаться над видео
    const allowedHorizontalMovement = Math.max(0, halfVideoWNew - halfCropW);
    minCenterX = overlayCenterX - allowedHorizontalMovement;
    maxCenterX = overlayCenterX + allowedHorizontalMovement;
    
    // Вертикальное движение: оверлей должен оставаться над видео
    const allowedVerticalMovement = Math.max(0, halfVideoHNew - halfCropH);
    minCenterY = overlayCenterY - allowedVerticalMovement;
    maxCenterY = overlayCenterY + allowedVerticalMovement;

    // dx = newCenterX - currentCenterX; dy аналогично
    const minDx = minCenterX - videoCenterXNow;
    const maxDx = maxCenterX - videoCenterXNow;
    const minDy = minCenterY - videoCenterYNow;
    const maxDy = maxCenterY - videoCenterYNow;
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
        console.log('Кнопка "Обрезать" нажата');
        
    if (!videoFile) {
            console.log('Видео не выбрано');
        if (typeof tg.showAlert === 'function') {
            tg.showAlert('Пожалуйста, выберите видео');
        } else {
            alert('Пожалуйста, выберите видео');
        }
        return;
    }

        console.log('Начинаем обработку видео');
        
        try {
            // Меняем кнопку на "Ожидайте" и делаем её неактивной
            cropButton.textContent = 'Ожидайте';
            cropButton.style.background = '#666';
            cropButton.disabled = true;
            
            // Показываем статус-индикатор
            console.log('Сбрасываем статус и показываем индикатор');
            resetProcessingStatus();
            showProcessingStatus();
            updateStatusStep('status-uploading');

        const video = document.getElementById('video-preview');
        const videoRect = video.getBoundingClientRect();
        const cropRect = cropFrame.getBoundingClientRect();
        
        // Получаем реальные размеры видео без учета масштаба
        const videoElement = videoPreview;
        const naturalWidth = videoElement.videoWidth;
        const naturalHeight = videoElement.videoHeight;
        
        // Размеры видео на экране (с учетом масштаба)
        const scaledVideoWidth = videoRect.width;
        const scaledVideoHeight = videoRect.height;
        
        // Центр видео на экране
        const videoCenterX = videoRect.left + videoRect.width / 2;
        const videoCenterY = videoRect.top + videoRect.height / 2;
        
        // Центр области кропа на экране
        const cropCenterX = cropRect.left + cropRect.width / 2;
        const cropCenterY = cropRect.top + cropRect.height / 2;
        
        // Смещение центра кропа относительно центра видео (в экранных пикселях)
        const screenOffsetX = cropCenterX - videoCenterX;
        const screenOffsetY = cropCenterY - videoCenterY;
        
        // Переводим экранные координаты в координаты исходного видео
        // Учитываем, что видео может быть масштабировано и смещено
        const videoOffsetX = screenOffsetX / currentScale;
        const videoOffsetY = screenOffsetY / currentScale;
        
        // Центр кропа в координатах исходного видео (относительно центра)
        const cropCenterInVideoX = videoOffsetX;
        const cropCenterInVideoY = videoOffsetY;
        
        // Переводим в нормализованные координаты (0-1)
        const x = Math.max(0, Math.min(1, 0.5 + cropCenterInVideoX / naturalWidth));
        const y = Math.max(0, Math.min(1, 0.5 + cropCenterInVideoY / naturalHeight));
        
        // Размер области кропа в координатах исходного видео
        const cropSizeInVideo = cropRect.width / currentScale;
        
        // Увеличиваем размер области кропа для отдаления итогового видео
        const aspectRatio = naturalWidth / naturalHeight;
        const cropPaddingFactor = aspectRatio > 1 ? 2.5 : 1.6; // +150% для горизонтального, +70% для вертикального
        
        const width = Math.min(1, (cropSizeInVideo * cropPaddingFactor) / naturalWidth);
        const height = Math.min(1, (cropSizeInVideo * cropPaddingFactor) / naturalHeight);

        const formData = new FormData();
        formData.append('video', videoFile);
        formData.append('cropData', JSON.stringify({
            x: x,
            y: y,
            width: width,
            height: height,
            scale: currentScale
        }));

        const initData = window.Telegram.WebApp.initDataUnsafe;
        if (!initData.user?.id) {
            throw new Error('Не удалось получить идентификатор чата');
        }
        formData.append('chatId', initData.user.id.toString());

        // Обновляем статус: видео загружено
        updateStatusStep('status-uploaded');
        
        // Обновляем статус: обработка видео
        setTimeout(() => updateStatusStep('status-processing'), 500);

        if (typeof tg.showProgress === 'function') {
            tg.showProgress();
        }

        console.log('Отправляем запрос на сервер...');
        const response = await fetch('/api/upload', {
            method: 'POST',
            body: formData
        });
        console.log('Получен ответ от сервера:', response.status);

        if (!response.ok) {
            const errorText = await response.text();
            throw new Error(errorText);
        }

        // Обновляем статус: создание кружка
        updateStatusStep('status-creating');
        
        // Имитируем время обработки
        setTimeout(() => {
            updateStatusStep('status-sent');
            
            // Показываем алерт завершения и закрываем через 2 секунды
            setTimeout(() => {
                hideProcessingStatus();
                showCompletionAlert();
                
                setTimeout(() => {
                    // Принудительно сбрасываем состояние перед закрытием
                    resetAppState();
                    if (typeof tg.close === 'function') {
                        tg.close();
                    }
                }, 3000);
            }, 1000);
        }, 1500);

    } catch (error) {
        console.error('Error:', error);
        hideProcessingStatus();
        
        // Возвращаем кнопку в исходное состояние
        cropButton.textContent = 'Обрезать';
        cropButton.style.background = 'var(--primary-color)';
        cropButton.disabled = false;
        
        // Сбрасываем состояние при ошибке
        resetAppState();
        if (typeof tg.showAlert === 'function') {
            tg.showAlert(error.message);
        } else {
            alert(error.message);
        }
    } finally {
        if (typeof tg.hideProgress === 'function') {
            tg.hideProgress();
        }
    }
}); 
} 